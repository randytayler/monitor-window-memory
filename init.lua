--[[============================================================================
  Monitor Window Memory
  ---------------------------------------------------------------------------
  Remembers where every window lives for each monitor arrangement, and puts
  them back when you disconnect / reconnect displays.

  How it works:
    * Each unique set of connected screens gets a "fingerprint".
    * Once windows have sat still for STABLE_SECONDS on a given fingerprint,
      that layout is saved as the known-good layout for that arrangement
      (persisted to disk, so it survives restarts / logouts).
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
local STABLE_SECONDS   = 6      -- how long windows must sit still before we save
local SAVE_POLL        = 4      -- how often (s) we check whether to snapshot
local RESTORE_DELAYS   = { 1.0, 2.5, 4.5 } -- retry restore at these delays (s) after a change
local SETTINGS_KEY     = "monitorWindowMemory.layouts"

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
-- layouts[fingerprint] = { entries = { {id, app, title, frame={x,y,w,h}}, ... } }
local layouts          = hs.settings.get(SETTINGS_KEY) or {}
local lastChangeTime   = os.time()
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
		if win:isStandard()
			and win:isVisible()
			and not win:isMinimized()
			and win:frame().w > 0
			and win:frame().h > 0 then
			out[#out + 1] = win
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

-- Score how well a saved entry matches a live window (higher = better).
local function matchScore(entry, win)
	local app = win:application()
	local bundle = app and app:bundleID() or nil
	if entry.id and entry.id == win:id() then
		return 100                       -- same window, best possible
	end
	if entry.app and bundle and entry.app == bundle then
		if entry.title ~= "" and entry.title == (win:title() or "") then
			return 50                    -- same app + same title
		end
		return 10                        -- same app, title drifted
	end
	return 0
end

-- Restore saved frames for the current fingerprint.
local function restoreLayout(reason)
	local fp = fingerprint()
	local saved = layouts[fp]
	if not saved or not saved.entries then
		return false
	end

	local wins = manageableWindows()
	local usedWin = {}

	-- For each saved entry, claim the best unused live window.
	for _, entry in ipairs(saved.entries) do
		local best, bestScore = nil, 0
		for _, win in ipairs(wins) do
			if not usedWin[win:id()] then
				local s = matchScore(entry, win)
				if s > bestScore then
					best, bestScore = win, s
				end
			end
		end
		if best and bestScore > 0 then
			usedWin[best:id()] = true
			best:setFrame(hs.geometry.rect(
				entry.frame.x, entry.frame.y, entry.frame.w, entry.frame.h), 0)
		end
	end

	if reason then
		hs.printf("[WindowMemory] restored layout for %d entries (%s)",
			#saved.entries, reason)
	end
	return true
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
-- Periodic saver: only snapshots once the arrangement has been stable a while,
-- so we never capture the "everything squished onto the laptop" transient.
-- ---------------------------------------------------------------------------
M.saveTimer = hs.timer.new(SAVE_POLL, function()
	if os.time() - lastChangeTime >= STABLE_SECONDS then
		local before = layouts[currentFingerprint or ""] ~= nil
		saveLayout(nil)   -- quiet periodic save
		if not before then updateMenu() end  -- flip "no layout saved" indicator
	end
end)
M.saveTimer:start()

-- ---------------------------------------------------------------------------
-- Screen watcher: on any arrangement change, restore the new arrangement's
-- saved layout (with retries), and reset the stability clock.
-- ---------------------------------------------------------------------------
M.screenWatcher = hs.screen.watcher.new(function()
	local fp = fingerprint()
	if fp == currentFingerprint then
		return   -- geometry re-report with no real change; ignore
	end
	currentFingerprint = fp
	lastChangeTime = os.time()
	hs.printf("[WindowMemory] screen change detected; new arrangement")
	updateMenu()

	-- Try to restore a few times; macOS keeps re-laying-out for a second or two
	-- after a display connects, so a single attempt often gets stomped.
	for _, delay in ipairs(RESTORE_DELAYS) do
		hs.timer.doAfter(delay, function()
			restoreLayout(string.format("+%.1fs after change", delay))
		end)
	end
end)
M.screenWatcher:start()

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
