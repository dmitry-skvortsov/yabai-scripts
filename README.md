# Window Management Helpers (yabai + skhd)

Small shell scripts for a macOS tiling setup based on `yabai`, `skhd`, and `borders`.

## What this repo provides

- A practical `yabai` config (`.yabairc`) with BSP layout defaults.
- A signal-driven focus recovery agent (`yabai-agent.sh`) for edge cases after close/minimize/space/display changes.
- Utility scripts for moving the current window across spaces and creating app windows on the current space.
- A lightweight controller for the `borders` process (`bordersctl.sh`).
- A stress/diagnostic script for focus reliability (`stress_agent.sh`).

## Scripts

### `yabai-agent.sh`

Event agent that subscribes to yabai signals and keeps focus behavior stable:

- Registers handlers for window/space/display lifecycle events.
- Debounces refocus attempts to avoid event storms.
- Restores focus when macOS leaves no focused window after close/minimize/app termination.
- Tracks last focused window per display/space and prefers it as a refocus target.
- Prunes stale focus history after topology changes.
- Reloads `borders` only on `dock_did_restart`.

Commands:

- `yabai-agent.sh start`
- `yabai-agent.sh stop`
- `yabai-agent.sh run`
- `yabai-agent.sh event <event> [id]`

### `bordersctl.sh`

Controller for the `borders` binary:

- `ensure`: start if not running.
- `reload`: hard restart with throttle protection.
- `maybe`: throttled ensure, skipped when suppression token exists.

Config is read from `borders.conf`.

### `move_focus.sh`

Moves the currently focused window to the next or previous space on the same display and keeps focus on that window:

- Usage: `move_focus.sh next` or `move_focus.sh prev`
- Skips native fullscreen spaces.
- Uses a temporary suppression token to avoid noisy side-effects during transition.

### `new_here.sh`

Creates a new app window and places/focuses it on the current space:

- Usage: `new_here.sh ghostty|chrome|zen`
- Spawns a new window using app-specific logic.
- Detects the newly created managed window by window id.
- Re-focuses current display/space and focuses the new window.

### `stress_agent.sh`

Quick stress tool for focus reliability and process leak checks:

- Usage: `stress_agent.sh [focus|close|query]`
- Generates repeated load against yabai.
- Captures before/after process snapshots.
- Prints focus miss stats for idle checks and space-switch checks.

## Keybindings (`.skhdrc`)

- Focus window: `fn + h | j | k | l`
- Swap window: `fn + ; | ' | [ | /`
- Move current window to prev/next space: `fn + a | s`
- Focus prev/next space: `fn + z | x`
- Create window here:
  - `fn + g` -> Ghostty
  - `fn + c` -> Chrome
  - `fn + b` -> Zen

## Setup

1. Install dependencies: `yabai`, `skhd`, `jq`, `borders`.
2. Place scripts/configs in your yabai config directory (for example `~/.config/yabai/`).
3. Make scripts executable:
   - `chmod +x yabai-agent.sh bordersctl.sh move_focus.sh new_here.sh stress_agent.sh`
4. Load/reload services:
   - `yabai --restart-service`
   - `skhd --reload`

## Notes

- Paths in scripts default to Homebrew locations (`/opt/homebrew/bin`).
- The setup expects accessibility permissions for yabai/borders/skhd.
- `sudo yabai --load-sa` is attempted when needed by config/agent logic.
