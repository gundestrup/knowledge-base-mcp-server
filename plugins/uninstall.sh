#!/usr/bin/env bash
# Remove the SwiftBar menu-bar plugin. Deliberately does NOT touch the
# launchd service, the auth token, mcp_config.json, or kb.config.yaml —
# uninstall only removes the menubar UI.
set -euo pipefail

ENV_FILE="${KB_MENUBAR_ENV:-$HOME/.config/kb/menubar.env}"
PLUGIN_DST="$HOME/Library/Application Support/SwiftBar/Plugins"

rm -f "$PLUGIN_DST/kb-mcp.10s.sh" "$PLUGIN_DST/kb-mcp-rebuild.sh" "$ENV_FILE"

echo "uninstall: removed kb-mcp plugin files and $(basename "$ENV_FILE")"
echo "uninstall: SwiftBar drops the menu item on its next refresh (~10s)"
echo "uninstall: server untouched — $HOME/Library/LaunchAgents/ai.knowledge-base.mcp.plist is still loaded"
