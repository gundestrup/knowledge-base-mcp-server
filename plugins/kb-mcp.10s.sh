#!/usr/bin/env bash
# <xbar.title>KB MCP</xbar.title>
# <xbar.version>v1.0</xbar.version>
# <xbar.author>Svend Gundestrup</xbar.author>
# <xbar.desc>Status + control for the launchd-managed knowledge-base MCP server</xbar.desc>
# <xbar.dependencies>bash,curl</xbar.dependencies>

# Paths are resolved at install time into ~/.config/kb/menubar.env —
# re-run plugins/install.sh after moving the repo or changing the port.
ENV_FILE="${KB_MENUBAR_ENV:-$HOME/.config/kb/menubar.env}"
[[ -f $ENV_FILE ]] && source "$ENV_FILE"

LABEL="${KB_MCP_LABEL:-ai.knowledge-base.mcp}"
PORT="${KB_MCP_PORT:-8090}"
BIND="${KB_MCP_BIND:-127.0.0.1}"
PLIST="${KB_MCP_PLIST:-$HOME/Library/LaunchAgents/${LABEL}.plist}"
LOG_ERR="${KB_MCP_LOG_ERR:-$HOME/Library/Logs/knowledge-base-mcp.err.log}"
LOG_OUT="${KB_MCP_LOG_OUT:-$HOME/Library/Logs/knowledge-base-mcp.out.log}"
MCP_CFG="${KB_MCP_CONFIG:-$HOME/.config/devin/mcp_config.json}"
DOMAIN="gui/$(id -u)/${LABEL}"
HEALTH="http://${BIND}:${PORT}/health"
HELPER="$(cd "$(dirname "$0")" && pwd)/kb-mcp-rebuild.sh"

state="$(launchctl print "$DOMAIN" 2>/dev/null | awk -F' = ' '$1 ~ /state/ {print $2; exit}')"
pid="$(launchctl print "$DOMAIN" 2>/dev/null | awk -F' = ' '$1 ~ /pid/ {print $2; exit}')"
health="$(curl -s -m 2 "$HEALTH" 2>/dev/null)"

if [[ "$state" == "running" && "$health" == *'"ok"'* ]]; then
  echo "KB ● | color=#2e7d32"
else
  echo "KB ● | color=#c62828"
fi
echo "---"
echo "state: ${state:-stopped}  pid: ${pid:-—} | size=11 color=gray"
echo "health: ${health:-unreachable} | size=11 color=gray"
echo "---"
echo "Rebuild + restart | bash=$HELPER terminal=true refresh=true"
echo "Restart | bash=/bin/launchctl param1=kickstart param2=-k param3=$DOMAIN terminal=false refresh=true"
echo "Stop | bash=/bin/launchctl param1=bootout param2=$DOMAIN terminal=false refresh=true"
echo "Start | bash=/bin/launchctl param1=bootstrap param2=gui/$(id -u) param3=$PLIST terminal=false refresh=true"
echo "---"
echo "Open error log | bash=/usr/bin/open param1=-a param2=Console param3=$LOG_ERR terminal=false"
echo "Open out log | bash=/usr/bin/open param1=-a param2=Console param3=$LOG_OUT terminal=false"
echo "Edit Devin MCP config | bash=/usr/bin/open param1=-t param2=$MCP_CFG terminal=false"
echo "---"
echo "Health endpoint | href=$HEALTH"
