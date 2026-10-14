#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INSTALLED_APP="$HOME/Applications/Dev Toolbox.app"
AGENT_PATH="$HOME/Library/LaunchAgents/local.pc2mac.devtoolbox.plist"
LABEL="local.pc2mac.devtoolbox"
GUI_DOMAIN="gui/$(id -u)"

case "${1:-enable}" in
  enable)
    if [[ ! -x "$PROJECT_DIR/dist/Dev Toolbox.app/Contents/MacOS/DevToolbox" ]]; then
      bash "$PROJECT_DIR/scripts/build.sh"
    fi
    mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
    ditto "$PROJECT_DIR/dist/Dev Toolbox.app" "$INSTALLED_APP"
    codesign --verify --deep --strict "$INSTALLED_APP"
    python3 - "$INSTALLED_APP/Contents/MacOS/DevToolbox" "$AGENT_PATH" <<'PY'
import plistlib
import sys
from pathlib import Path
config = {
    "Label": "local.pc2mac.devtoolbox",
    "ProgramArguments": [sys.argv[1]],
    "RunAtLoad": True,
    "ProcessType": "Interactive",
    "AssociatedBundleIdentifiers": ["local.pc2mac.devtoolbox"],
}
Path(sys.argv[2]).write_bytes(plistlib.dumps(config))
PY
    plutil -lint "$AGENT_PATH"
    launchctl bootout "$GUI_DOMAIN/$LABEL" 2>/dev/null || true
    pkill -x DevToolbox 2>/dev/null || true
    launchctl enable "$GUI_DOMAIN/$LABEL"
    launchctl bootstrap "$GUI_DOMAIN" "$AGENT_PATH"
    printf 'Enabled login startup: %s\n' "$INSTALLED_APP"
    ;;
  disable)
    launchctl bootout "$GUI_DOMAIN/$LABEL" 2>/dev/null || true
    if [[ -f "$AGENT_PATH" ]]; then
      mv "$AGENT_PATH" "$AGENT_PATH.disabled"
    fi
    printf 'Disabled login startup. Launch the application manually when needed.\n'
    ;;
  *)
    printf 'Usage: bash scripts/configure-autostart.sh [enable|disable]\n' >&2
    exit 1
    ;;
esac
