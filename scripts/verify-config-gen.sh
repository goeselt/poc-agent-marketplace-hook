#!/usr/bin/env bash
# Hermetic E2E for the plugin-config.json generator spike: generated dependency hooks must
# provision an own-marketplace dep AND an external-marketplace dep (incl. nested marketplace add).
set -euo pipefail

command -v claude >/dev/null || { printf 'claude CLI not found\n' >&2; exit 1; }
readonly PocRoot="$(cd "$(dirname "$0")/.." && pwd)"
readonly Work="$(mktemp -d)"
trap 'rm -rf "$Work"' EXIT

export CLAUDE_CONFIG_DIR="$Work/config"
export POC_MARKER_DIR="$Work/markers"
mkdir -p "$CLAUDE_CONFIG_DIR" "$POC_MARKER_DIR"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok: %s\n' "$1" >&2; }
session() { rm -f "$POC_MARKER_DIR"/*; env -u ANTHROPIC_API_KEY claude -p "say ok" >/dev/null 2>&1 || true; }
installed() { claude plugin list --json 2>/dev/null | grep -c "\"id\": \"$1\"" || true; }

# Hermetic external marketplace: a local copy of marketplace/ stands in for the git source
# (the authored git form 'owner/repo#claude' is proven separately -- finding G1).
cp -r "$PocRoot/marketplace" "$Work/external-marketplace"
cp -r "$PocRoot/authoring" "$Work/authoring"
node -e "
const fs = require('fs')
const f = '$Work/authoring/plugins/dep-a/plugin-config.json'
const c = JSON.parse(fs.readFileSync(f, 'utf8'))
c.dependencies.find((d) => d.marketplace === 'poc-hook').source = '$Work/external-marketplace'
fs.writeFileSync(f, JSON.stringify(c, null, 2))"

node "$PocRoot/src/generate.js" "$Work/authoring" "$Work/out" 2>/dev/null
claude plugin validate "$Work/out" --strict >/dev/null 2>&1 || fail "generated marketplace fails validate --strict"
pass "generated marketplace passes claude plugin validate --strict"

claude plugin marketplace add "$Work/out" >/dev/null 2>&1
claude plugin install dep-a@poc-config >/dev/null 2>&1
[[ "$(installed dep-a@poc-config)" == 1 ]] || fail "precondition: dep-a installed"

# Session 1: generated hook must install dep-b (own mp) AND hook-c (external mp incl. marketplace add)
session
[[ -f "$POC_MARKER_DIR/dep-a.authored" ]] || fail "authored hook lost in merge"
pass "authored hook survived the merge and fired"
grep -q 'marketplace=poc-hook added_from=' "$POC_MARKER_DIR/ensure-deps.log" \
  || fail "nested 'plugin marketplace add' from the hook did not run/succeed"
pass "external marketplace registered from inside the hook"
[[ "$(installed dep-b@poc-config)" == 1 ]] || fail "own-marketplace dependency dep-b not installed"
[[ "$(installed hook-c@poc-hook)" == 1 ]] || fail "external dependency hook-c not installed"
pass "both dependencies installed in session 1"

# Session 2: the external dependency's own hook must be active now
session
[[ -f "$POC_MARKER_DIR/hook-c.sessionstart" ]] || fail "external dependency's hook not active in session 2"
grep -q 'dep=dep-b@poc-config status=present' "$POC_MARKER_DIR/ensure-deps.log" \
  || fail "ensure-deps should report dep-b present on re-run"
pass "external dependency active; re-run is a clean no-op"

printf 'config-generator spike verified\n' >&2
