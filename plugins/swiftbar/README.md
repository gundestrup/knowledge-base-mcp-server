# plugins/ — macOS menu-bar control for the local MCP server

Fork-local tooling (listed in `FORK-ONLY`; never goes to upstream PRs).
A [SwiftBar](https://swiftbar.app) plugin that puts a status icon in the
macOS menu bar for the launchd-managed `knowledge-base-mcp-server`
(`ai.knowledge-base.mcp`, `MCP_TRANSPORT=http`).

## Requires

- macOS + SwiftBar (`brew install --cask swiftbar`, or run the installer
  with `--install-swiftbar` and it will install it via Homebrew for you)
- The launchd HTTP server already installed, loaded, and healthy
  (see `FORK-NOTES.md` §Local MCP server — the installer refuses to run
  otherwise)
- `node` (used to resolve config; already a server dependency)

## Install / uninstall

```bash
plugins/swiftbar/install.sh     # preflight checks → resolve config → install
plugins/swiftbar/uninstall.sh   # removes the plugin + menubar.env only
```

The installer verifies **before touching anything**: SwiftBar present,
`launchctl` service loaded and running, `http://<bind>:<port>/health`
returning `{"status":"ok"}`. It never modifies the service, the auth
token, `mcp_config.json`, or `kb.config.yaml`.

## How config is resolved

```
launchd plist > ~/.config/devin/mcp_config.json > ~/.config/kb/kb.config.yaml > defaults
```

Resolved values are written to `~/.config/kb/menubar.env`, which both
plugin scripts `source` at runtime — the scripts themselves stay
generic. Re-run `install.sh` after moving the repo, changing the port,
or renaming the service.

## Menu

`KB ●` — green when launchd reports `running` and `/health` is ok, red
otherwise. Dropdown: **Rebuild + restart** (npm build → kickstart, in a
Terminal window), Restart, Stop, Start, log files (Console), Devin MCP
config, `/health` link.

## Files

| File | Role |
|---|---|
| `kb-mcp.10s.sh` | SwiftBar plugin (refresh every 10 s), copied to `~/Library/Application Support/SwiftBar/Plugins/` |
| `kb-mcp-rebuild.sh` | `npm run build` + `launchctl kickstart -k` + health check |
| `install.sh` | preflight + config resolution + install |
| `uninstall.sh` | removes plugin files + `menubar.env` only |
