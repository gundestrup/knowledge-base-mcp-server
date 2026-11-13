# Fork workflow notes

This fork (`gundestrup/knowledge-base-mcp-server`) tracks upstream
`jeanibarz/knowledge-base-mcp-server`. `main` carries a few fork-local
files that must never reach upstream — see `FORK-ONLY` for the list and
the reason for each entry.

## Contributing a change upstream

```bash
scripts/prepare-upstream-branch.sh <branch-name>   # strips FORK-ONLY paths
git push -u origin <branch-name>
gh pr create --repo jeanibarz/knowledge-base-mcp-server --head gundestrup:<branch-name> ...
```

The strip is a separate commit on the PR branch, so `main` keeps the
fork-local files. After upstream merges, delete the branch — it's a
one-way snapshot.

## Rules of thumb

- **Fork-local** = anything bound to this account or machine: SonarQube
  Cloud org/project/token, IDE bindings, this tooling itself.
- **Upstream-safe** = dependency bumps, CI hardening, bug fixes, tests —
  anything a maintainer could merge without owning your secrets.
- Adding a new private file? Append it to `FORK-ONLY` so the next PR
  branch strips it automatically.
- Sync after upstream merges: `git merge upstream/main`. Expect trivial
  conflicts in `package.json`/`package-lock.json` where both sides made
  the same edit — take either; they're identical.

## Currently excluded files

- `.vscode/settings.json` — SonarLint connected-mode binding (personal connection id). Directory-level entry removed: upstream owns `.vscode/launch.json` (#1147).
- `sonar-project.properties`, `.github/workflows/sonar.yml` — SonarQube
  Cloud project + `SONAR_TOKEN` belong to this fork's account
- `FORK-ONLY`, `FORK-NOTES.md`, `scripts/prepare-upstream-branch.sh` —
  this machinery is internal

## PR body: build from the template, never by hand

Upstream's anti-drift workflow counts `kookr:check:*` markers in the PR body
against the merge-base diff. A body composed via `--body` that omits a marker
fails before review — this bit us twice on #1070/#1071.

Workflow:

```bash
scripts/prepare-pr-body.sh /tmp/pr-body.md   # copies the template + lists diff categories
# edit /tmp/pr-body.md — fill Summary/Fixes, check or strike every row
scripts/prepare-pr-body.sh --check /tmp/pr-body.md
gh pr create --repo jeanibarz/knowledge-base-mcp-server \
  --head gundestrup:<branch> --base main \
  --title "..." --body-file /tmp/pr-body.md
```

Semantics: a CHECKED row requires a matching file in the diff
(`tests`→test files, `docs`→`docs/`, `benchmarks`→`benchmarks/`,
`changelog`→`CHANGELOG.md`). Genuinely-N/A rows are struck through with a
one-line reason — that is a valid waiver, not a failure. Evidence that
doesn't live in a matching file (e.g. test assertions for a perf change)
belongs in the waiver reason.

## Local MCP server (launchd, HTTP transport)

Devin/Windsurf sessions connect to ONE persistent server instead of
spawning `node build/index.js` per session — removes the per-session
index-load/cold-embed penalty (engineering-memory session note 2026-11-04).

- Service: `ai.knowledge-base.mcp` → `~/Library/LaunchAgents/ai.knowledge-base.mcp.plist`
- Endpoint: `http://127.0.0.1:8090/mcp` (`/health` unauthenticated;
  `/ready` and `/mcp` need the bearer token). Port 8081 belongs to the
  KBM-flow dashboard — do not reuse it.
- Token: `~/.config/kb/mcp-auth-token` (0600), server reads it via
  `MCP_AUTH_TOKEN_FILE`; client headers carry it in
  `~/.config/devin/mcp_config.json` (`url` + `transport: http`).
- Logs: `~/Library/Logs/knowledge-base-mcp.{out,err}.log`

### Upgrade flow

```bash
git merge upstream/main                                   # sync fork
npm run build                                             # rebuild build/
launchctl kickstart -k gui/$(id -u)/ai.knowledge-base.mcp # reload service
curl -s http://127.0.0.1:8090/health                      # expect {"status":"ok"}
```

The plist runs `build/index.js`, so a rebuild alone changes nothing until
the kickstart. Running sessions keep their already-loaded code — they
pick up the new build on their next launch/connect.

### Manage

```bash
launchctl print gui/$(id -u)/ai.knowledge-base.mcp        # status/PID
launchctl kickstart -k gui/$(id -u)/ai.knowledge-base.mcp # restart
launchctl bootout gui/$(id -u)/ai.knowledge-base.mcp      # stop for good
```
