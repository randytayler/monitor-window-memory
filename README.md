# Monitor Window Memory

Remembers where every window lives for each monitor arrangement, and puts them
back when you disconnect / reconnect displays.

Built on [Hammerspoon](https://www.hammerspoon.org/). Fixes the classic macOS
annoyance where unplugging your externals squishes every window onto the laptop
screen — and reconnecting doesn't put them back.

## What it does

- Fingerprints each set of connected screens (e.g. "laptop only" vs
  "laptop + 2 externals").
- Once your windows sit still for a few seconds, it quietly saves that layout
  for the current arrangement (persisted to disk, survives reboots).
- When you change monitors, it detects the arrangement and restores the saved
  layout — retrying a few times to beat macOS's own reshuffle.
- A menubar readout (🖥 + screen count) shows the active arrangement and lets
  you save / restore / forget layouts by hand.

Hotkeys:

| Shortcut | Action |
|----------|--------|
| `⌥⌘S` | Save the current layout for this monitor setup now |
| `⌥⌘R` | Restore the saved layout for this monitor setup now |

## Install

### One command

```bash
git clone https://github.com/randytayler/monitor-window-memory.git
cd monitor-window-memory
./install.sh
```

The installer will:
1. Install Hammerspoon via Homebrew (if you don't already have it).
2. Copy the config into `~/.hammerspoon/init.lua` (backing up any existing one).
3. Launch Hammerspoon and open the Accessibility settings pane.

### Manual

1. Install Hammerspoon: `brew install --cask hammerspoon` (or from
   [hammerspoon.org](https://www.hammerspoon.org/)).
2. Copy [`init.lua`](init.lua) to `~/.hammerspoon/init.lua`.
3. Launch Hammerspoon.

## The one manual step: Accessibility permission

macOS won't let **any** app move windows until you allow it, and this can't be
scripted (it's an OS security setting):

**System Settings ▸ Privacy & Security ▸ Accessibility → enable Hammerspoon**

Then: Hammerspoon menubar icon ▸ **Reload Config**.

> Saving your layout works without this. *Restoring* windows needs it.

## Using it

1. With all your monitors connected, arrange windows how you like them. Leave
   them ~6 seconds — the layout auto-saves for that arrangement.
2. Disconnect. Windows collapse onto the laptop; that layout gets saved too.
3. Reconnect. Your windows snap back to where they were.

The first reconnect after installing may have nothing to restore yet — it needs
to see (and save) your good multi-monitor layout at least once first.

## Heads up if you already use Hammerspoon

This ships as a whole `init.lua`, so the installer **replaces** your existing
config (after backing it up). If you already have a Hammerspoon setup you want
to keep, don't use `install.sh` — instead copy the body of [`init.lua`](init.lua)
into your own config, or package it as a Spoon.

## Tuning

Open [`init.lua`](init.lua) and edit the values near the top:

- `STABLE_SECONDS` — how long windows must sit still before a layout is saved.
- `RESTORE_DELAYS` — when (seconds after a monitor change) restore is retried.
  If restores land slightly off, add more / later delays here.
