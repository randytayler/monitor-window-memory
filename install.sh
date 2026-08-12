#!/usr/bin/env bash
#
# Monitor Window Memory — installer
# ---------------------------------
# Installs Hammerspoon (if needed) and drops in the config that remembers and
# restores your window layout when you connect / disconnect monitors.
#
# Run it from a checkout of this folder:
#     ./install.sh
#
# Safe to re-run. If you already have a ~/.hammerspoon/init.lua, it is backed
# up (never silently overwritten).

set -euo pipefail

HS_DIR="$HOME/.hammerspoon"
TARGET="$HS_DIR/init.lua"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$SCRIPT_DIR/init.lua"

say() { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m!! \033[0m %s\n' "$1"; }

# --- sanity ---------------------------------------------------------------
if [[ "$(uname)" != "Darwin" ]]; then
	echo "This tool is macOS-only." >&2
	exit 1
fi
if [[ ! -f "$SOURCE" ]]; then
	echo "Can't find init.lua next to this script ($SOURCE)." >&2
	exit 1
fi

# --- 1. Hammerspoon -------------------------------------------------------
if [[ -d "/Applications/Hammerspoon.app" ]]; then
	say "Hammerspoon already installed."
else
	if command -v brew >/dev/null 2>&1; then
		say "Installing Hammerspoon via Homebrew..."
		brew install --cask hammerspoon
	else
		warn "Homebrew not found. Install Hammerspoon manually from"
		warn "https://www.hammerspoon.org/ then re-run this script."
		exit 1
	fi
fi

# --- 2. Config ------------------------------------------------------------
mkdir -p "$HS_DIR"
if [[ -f "$TARGET" ]] && ! cmp -s "$TARGET" "$SOURCE"; then
	BACKUP="$TARGET.backup-$(date +%Y%m%d-%H%M%S)"
	warn "Existing init.lua found — backing it up to:"
	warn "  $BACKUP"
	cp "$TARGET" "$BACKUP"
fi
cp "$SOURCE" "$TARGET"
say "Installed config to $TARGET"

# --- 3. (Re)launch Hammerspoon -------------------------------------------
if pgrep -x Hammerspoon >/dev/null 2>&1; then
	say "Restarting Hammerspoon to load the config..."
	osascript -e 'quit app "Hammerspoon"' >/dev/null 2>&1 || true
	sleep 1
fi
open -a Hammerspoon

# --- 4. Accessibility (the one manual step) ------------------------------
cat <<'EOF'

------------------------------------------------------------------------
 ONE MANUAL STEP LEFT — grant Accessibility permission
------------------------------------------------------------------------
 macOS won't let any app move windows until you allow it. This CANNOT be
 automated (it's an OS security setting).

 In the window that just opened:
   System Settings ▸ Privacy & Security ▸ Accessibility
   → turn ON the switch next to "Hammerspoon"

 Then click the Hammerspoon menubar icon (🖥) ▸ Reload Config.

 Saving your layout works without this; RESTORING windows needs it.
------------------------------------------------------------------------
EOF

open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" >/dev/null 2>&1 || true

say "Done. Look for the 🖥 icon in your menubar."
