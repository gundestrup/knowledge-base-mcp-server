#!/usr/bin/env bash
# kb-mcp-backfill.sh — run `kb reindex --with-context` (the contextual-
# preface backfill) in a Terminal window. Invoked from the SwiftBar
# "Context backfill" menu action; also usable directly from a shell.
#
# Resume semantics: files with complete sidecars are served from the
# preface cache, so re-running is cheap — only pending / failed chunks
# call the LLM.
#
# `--force` is deliberate: this is an explicit user action, so the
# 06:00-10:30 UTC cron-window and runtime-budget guards (which protect
# unattended invocations) do not apply.
ENV_FILE="${KB_MENUBAR_ENV:-$HOME/.config/kb/menubar.env}"
# shellcheck source=/dev/null
[[ -f $ENV_FILE ]] && source "$ENV_FILE"

REPO="${KB_MCP_REPO:-$HOME/workspace/knowledge-base-mcp-server}"
NODE="${KB_MCP_NODE:-node}"
PLIST="${KB_MCP_PLIST:-$HOME/Library/LaunchAgents/${KB_MCP_LABEL:-ai.knowledge-base.mcp}.plist}"

# The CLI resolves its index dir from env; mirror the launchd service's
# config (resolved into menubar.env by install.sh) so the run covers
# the same corpus the running server sees.
[[ -n ${KB_KB_ROOT:-} ]] && export KNOWLEDGE_BASES_ROOT_DIR="$KB_KB_ROOT"
[[ -n ${KB_FAISS_INDEX_PATH:-} ]] && export FAISS_INDEX_PATH="$KB_FAISS_INDEX_PATH"

# Embedding + contextual-preface config lives in the launchd plist —
# export whatever is set there so the CLI run uses the same provider,
# model, and budget settings as the server. Single source of truth;
# PlistBuddy exits non-zero for absent keys, which we ignore.
if [[ -f $PLIST ]]; then
  for key in EMBEDDING_PROVIDER OLLAMA_BASE_URL OLLAMA_MODEL \
             KB_CONTEXTUAL_RETRIEVAL KB_CONTEXTUAL_MAX_TOKENS \
             KB_CONTEXTUAL_CONCURRENCY KB_LLM_ENDPOINT KB_LLM_MODEL \
             KB_LLM_PROVIDER; do
    if v="$(/usr/libexec/PlistBuddy -c "Print :EnvironmentVariables:${key}" "$PLIST" 2>/dev/null)"; then
      export "$key=$v"
    fi
  done
fi

if [[ ${KB_CONTEXTUAL_RETRIEVAL:-} != "on" ]]; then
  echo "KB_CONTEXTUAL_RETRIEVAL is not 'on' in $PLIST —"
  echo "contextual prefaces are disabled; there is nothing to backfill."
  echo "(Set it in the plist, restart the service, then re-run.)"
  echo
  read -r -n 1 -p "press any key to close…" || true
  exit 1
fi

"$NODE" "$REPO/build/cli.js" reindex --with-context --force
echo
read -r -n 1 -p "press any key to close…" || true
