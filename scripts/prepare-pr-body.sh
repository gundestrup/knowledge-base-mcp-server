#!/usr/bin/env bash
# prepare-pr-body.sh [--check] <body-file>
#
# Builds (or validates) an upstream PR body from
# .github/PULL_REQUEST_TEMPLATE.md. The upstream anti-drift workflow counts
# kookr:check markers against the merge-base diff — a body composed by hand
# that omits a marker fails CI before review.
#
#   scripts/prepare-pr-body.sh /tmp/pr-body.md     # copy template → file
#   # edit /tmp/pr-body.md: fill Summary/Fixes, check or strike each row
#   scripts/prepare-pr-body.sh --check /tmp/pr-body.md
#   gh pr create --body-file /tmp/pr-body.md --title "..." ...
#
# Semantics: a CHECKED row requires a matching file in the PR diff
# (tests→test files, docs→docs/, benchmarks→benchmarks/, changelog→CHANGELOG).
# Genuinely-N/A rows should be struck through with a one-line reason; that is
# a waiver, not a failure. --check also reports which diff categories are
# present so row decisions are informed.
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
template="$root/.github/PULL_REQUEST_TEMPLATE.md"
mode="init"; out="${1:-}"
if [[ "$1" == "--check" ]]; then mode="check"; out="${2:?usage: $0 --check <body-file>}"; fi
[[ "$mode" == "init" && -z "$out" ]] && { echo "usage: $0 [--check] <body-file>" >&2; exit 1; }
[[ -f "$template" ]] || { echo "error: no PR template at $template" >&2; exit 1; }

markers() { grep -oE 'kookr:check:[a-z]+' "$1" | sort -u; }

if [[ "$mode" == "init" ]]; then
  cp "$template" "$out"
  echo "template copied to $out — fill it, then run: $0 --check $out" >&2
  echo "diff categories vs merge base:" >&2
  base=$(git merge-base HEAD "${UPSTREAM_REF:-upstream/main}" 2>/dev/null || git merge-base HEAD origin/main)
  git diff --name-only "$base"...HEAD | sed 's|/.*||' | sort -u | sed 's/^/  /' >&2
  exit 0
fi

[[ -f "$out" ]] || { echo "error: body file $out not found" >&2; exit 1; }
missing=$(comm -23 <(markers "$template") <(markers "$out"))
if [[ -n "$missing" ]]; then
  echo "FAIL — template markers missing from body:" >&2
  echo "$missing" | sed 's/^/  /' >&2
  exit 1
fi
echo "OK — all $(markers "$template" | wc -l | tr -d ' ') kookr:check rows present" >&2
