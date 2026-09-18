--[[============================================================================
  Monitor Window Memory
  ---------------------------------------------------------------------------
  Remembers where every window lives for each monitor arrangement, and puts
  them back when you disconnect / reconnect displays.

  How it works:
    * Each unique set of connected screens gets a "fingerprint".
    * You save the current window layout for an arrangement explicitly, with
      ⌥⌘S (or the menubar "Save layout now"). It's persisted to disk so it
      survives restarts / logouts. Nothing is saved automatically.
    * When the screen setup changes, if we have a saved layout for the new
      fingerprint, we restore it -- with a few retries to beat macOS's own
      re-layout that fires right after a display connects.

  Hotkeys (escape hatches):
    ⌥⌘S  save the current layout for this arrangement right now
    ⌥⌘R  restore the saved layout for this arrangement right now

  Requires: Hammerspoon must be granted Accessibility permission
  (System Settings ▸ Privacy & Security ▸ Accessibility).
============================================================================]]--

local M = {}

require("hs.ipc")   -- enables the `hs` command-line tool

-- ---------------------------------------------------------------------------
-- Tunables
-- ---------------------------------------------------------------------------
local RESTORE_DELAYS   = { 1.0, 2.5, 4.5 } -- retry restore at these delays (s) after a change
local SETTINGS_KEY     = "monitorWindowMemory.layouts"

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
-- layouts[fingerprint] = { entries = { {id, app, title, frame={x,y,w,h}}, ... } }
local layouts          = hs.settings.get(SETTINGS_KEY) or {}
local currentFingerprint = nil
local menu             = hs.menubar.new()

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- A stable id for the current arrangement: sorted screen UUIDs + geometry.
local function fingerprint()
	local parts = {}
	for _, scr in ipairs(hs.screen.allScreens()) do
		local f = scr:fullFrame()
		local uuid = scr:getUUID() or scr:name() or "?"
		parts[#parts + 1] = string.format("%s@%d,%d,%d,%d",
			uuid, f.x, f.y, f.w, f.h)
	end
	table.sort(parts)
	return table.concat(parts, "|")
end

-- Count screens encoded in a fingerprint (one "@" per screen).
local function fpScreenCount(fp)
	if not fp or fp == "" then return 0 end
	local n = 0
	for _ in fp:gmatch("@") do n = n + 1 end
	return n
end

-- Human label like "2 displays" for a fingerprint.
local function fpLabel(fp)
	local n = fpScreenCount(fp)
	return n == 1 and "1 display" or (n .. " displays")
end

-- Windows we care about: standard, visible, non-minimized app windows.
local function manageableWindows()
	local out = {}
	for _, win in ipairs(hs.window.allWindows()) do
		if win:isStandard() and win:isVisible() and not win:isMinimized() then
			local f = win:frame()
			if f.w > 0 and f.h > 0 then
				out[#out + 1] = win
			end
		end
	end
	return out
end

local function persist()
	hs.settings.set(SETTINGS_KEY, layouts)
end

-- Snapshot the current layout and store it under the current fingerprint.
local function saveLayout(reason)
	local fp = fingerprint()
	local entries = {}
	for _, win in ipairs(manageableWindows()) do
		local app = win:application()
		local f = win:frame()
		entries[#entries + 1] = {
			id    = win:id(),
			app   = app and app:bundleID() or nil,
			title = win:title() or "",
			frame = { x = f.x, y = f.y, w = f.w, h = f.h },
		}
	end
	if #entries == 0 then return end
	layouts[fp] = { entries = entries }
	persist()
	if reason then
		hs.printf("[WindowMemory] saved %d windows (%s)", #entries, reason)
	end
end

-- Squared distance between the centres of a saved frame and a live window.
local function centerDist2(entry, f)
	local dx = (f.x + f.w / 2) - (entry.frame.x + entry.frame.w / 2)
	local dy = (f.y + f.h / 2) - (entry.frame.y + entry.frame.h / 2)
	return dx * dx + dy * dy
end

-- Restore saved frames for the current fingerprint.
--
-- Matching a saved entry to a live window is done in two passes, because some
-- apps (browsers especially) recycle their window IDs *and* rewrite their
-- titles as tabs change, so neither is a reliable identity across sleep:
--
--   1. Exact window-ID match -- pins well-behaved apps (Slack, Terminal, Notes,
--      etc.) that keep stable IDs.
--   2. Nearest current position, within the same app -- for the churn-y apps.
--      Matching by proximity means a window that is ALREADY in the right place
--      stays put (distance 0 wins) instead of being cross-assigned to another
--      of the app's windows, which is what caused windows to swap screens.
local function restoreLayout(reason)
	local fp = fingerprint()
	local saved = layouts[fp]
	if not saved or not saved.entries then
		return false
	end

	local wins = manageableWindows()
	local usedWin = {}          -- win:id() -> true
	local assign = {}           -- saved entry index -> window

	-- Pass 1: exact window-ID match.
	for i, entry in ipairs(saved.entries) do
		if entry.id then
			for _, win in ipairs(wins) do
				if not usedWin[win:id()] and win:id() == entry.id then
					assign[i] = win
					usedWin[win:id()] = true
					break
				end
			end
		end
	end

	-- Pass 2: for still-unmatched entries, pair with same-app windows by
	-- nearest position. Build every candidate pair, then greedily take the
	-- closest pairs first so each window lands in the slot it's already nearest.
	local candidates = {}
	for i, entry in ipairs(saved.entries) do
		if not assign[i] and entry.app then
			for _, win in ipairs(wins) do
				if not usedWin[win:id()] then
					local app = win:application()
					if app and app:bundleID() == entry.app then
						candidates[#candidates + 1] =
							{ i = i, win = win, d = centerDist2(entry, win:frame()) }
					end
				end
			end
		end
	end
	table.sort(candidates, function(a, b) return a.d < b.d end)
	for _, c in ipairs(candidates) do
		if not assign[c.i] and not usedWin[c.win:id()] then
			assign[c.i] = c.win
			usedWin[c.win:id()] = true
		end
	end

	-- Apply.
	local applied = 0
	for i, entry in ipairs(saved.entries) do
		local win = assign[i]
		if win then
			win:setFrame(hs.geometry.rect(
				entry.frame.x, entry.frame.y, entry.frame.w, entry.frame.h), 0)
			applied = applied + 1
		end
	end

	if reason then
		hs.printf("[WindowMemory] restored %d/%d windows (%s)",
			applied, #saved.entries, reason)
	end
	return true
end

-- Restore several times over a few seconds. macOS keeps re-laying-out windows
-- for a second or two after a display connects or the machine wakes, so a
-- single attempt often gets stomped.
local function scheduleRestore(reason)
	for _, delay in ipairs(RESTORE_DELAYS) do
		hs.timer.doAfter(delay, function()
			restoreLayout(string.format("%s +%.1fs", reason, delay))
		end)
	end
end

-- ---------------------------------------------------------------------------
-- Menubar readout: shows the current arrangement and its saved-layout status,
-- with a dropdown listing every arrangement we know about.
-- ---------------------------------------------------------------------------
local function updateMenu()
	if not menu then return end

	local fp = currentFingerprint or fingerprint()
	local n = fpScreenCount(fp)
	local haveSaved = layouts[fp] ~= nil

	-- Title: monitor glyph + screen count, with a dot when this arrangement
	-- has no saved layout yet.
	menu:setTitle(string.format("🖥%d%s", n, haveSaved and "" or "•"))
	menu:setTooltip("Monitor Window Memory — " .. fpLabel(fp)
		.. (haveSaved and " (layout saved)" or " (no layout saved yet)"))

	local items = {
		{ title = "Now: " .. fpLabel(fp), disabled = true },
		{ title = haveSaved
			and ("✓ Layout saved (" .. #layouts[fp].entries .. " windows)")
			or  "• No layout saved for this setup yet", disabled = true },
		{ title = "-" },
		{ title = "Save layout now  (⌥⌘S)", fn = function()
			saveLayout("menubar")
			updateMenu()
			hs.alert.show("Window layout saved")
		end },
		{ title = "Restore layout now  (⌥⌘R)", disabled = not haveSaved,
			fn = function()
				restoreLayout("menubar")
				hs.alert.show("Window layout restored")
			end },
		{ title = "-" },
		{ title = "Saved arrangements", disabled = true },
	}

	-- List every known arrangement (checkmark on the active one).
	local count = 0
	for savedFp, data in pairs(layouts) do
		count = count + 1
		local mark = (savedFp == fp) and "  ● " or "     "
		items[#items + 1] = {
			title = string.format("%s%s — %d windows",
				mark, fpLabel(savedFp), #data.entries),
			disabled = true,
		}
	end
	if count == 0 then
		items[#items + 1] = { title = "     (none yet)", disabled = true }
	end

	items[#items + 1] = { title = "-" }
	items[#items + 1] = { title = "Forget this arrangement",
		disabled = not haveSaved, fn = function()
			layouts[fp] = nil
			persist()
			updateMenu()
			hs.alert.show("Forgot saved layout for " .. fpLabel(fp))
		end }
	items[#items + 1] = { title = "Open Console",
		fn = function() hs.openConsole() end }
	items[#items + 1] = { title = "Reload Config",
		fn = function() hs.reload() end }

	menu:setMenu(items)
end

-- ---------------------------------------------------------------------------
-- Screen watcher: on any arrangement change, restore the new arrangement's
-- saved layout (with retries). Layouts are only ever saved on demand (⌥⌘S or
-- the menubar), so there is no background work here.
-- ---------------------------------------------------------------------------
M.screenWatcher = hs.screen.watcher.new(function()
	local fp = fingerprint()
	if fp == currentFingerprint then
		return   -- geometry re-report with no real change; ignore
	end
	currentFingerprint = fp
	hs.printf("[WindowMemory] screen change detected; new arrangement")
	updateMenu()
	scheduleRestore("screen change")
end)
M.screenWatcher:start()

-- ---------------------------------------------------------------------------
-- Wake watcher: waking from sleep usually reconnects the SAME monitor
-- arrangement, so the screen watcher above sees no change and won't fire -- yet
-- macOS has already shuffled windows across screens during sleep. Restore on
-- wake / unlock to put them back. Also refresh currentFingerprint in case the
-- arrangement really did change while asleep.
-- ---------------------------------------------------------------------------
M.wakeWatcher = hs.caffeinate.watcher.new(function(event)
	local w = hs.caffeinate.watcher
	if event == w.systemDidWake
		or event == w.screensDidWake
		or event == w.screensDidUnlock then
		currentFingerprint = fingerprint()
		updateMenu()
		hs.printf("[WindowMemory] wake/unlock detected; restoring")
		scheduleRestore("wake")
	end
end)
M.wakeWatcher:start()

-- ---------------------------------------------------------------------------
-- Manual hotkeys
-- ---------------------------------------------------------------------------
hs.hotkey.bind({ "alt", "cmd" }, "S", function()
	saveLayout("manual ⌥⌘S")
	updateMenu()
	hs.alert.show("Window layout saved for this monitor setup")
end)

hs.hotkey.bind({ "alt", "cmd" }, "R", function()
	if restoreLayout("manual ⌥⌘R") then
		hs.alert.show("Window layout restored")
	else
		hs.alert.show("No saved layout for this monitor setup yet")
	end
end)

-- ---------------------------------------------------------------------------
-- Init
-- ---------------------------------------------------------------------------
currentFingerprint = fingerprint()
hs.autoLaunch(true)   -- start Hammerspoon automatically at login
updateMenu()
hs.alert.show("Monitor Window Memory loaded")
hs.printf("[WindowMemory] loaded; %d saved arrangement(s)",
	(function() local n = 0 for _ in pairs(layouts) do n = n + 1 end return n end)())

return M
