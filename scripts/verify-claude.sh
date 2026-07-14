#!/usr/bin/env bash
# Hermetic verification of the hook-based dependency findings (F1, F3-F6) -- no auth, no network.
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

session() { # run one unauthenticated print session; hooks fire, model never runs
  rm -f "$POC_MARKER_DIR"/*
  env -u ANTHROPIC_API_KEY claude -p "say ok" >/dev/null 2>&1 || true
}

installed() { claude plugin list --json 2>/dev/null | grep -c "\"id\": \"$1@poc-hook\"" || true; }

# Work on a disposable copy of the marketplace so the update test can bump versions freely.
cp -r "$PocRoot/marketplace" "$Work/marketplace"
claude plugin marketplace add "$Work/marketplace" >/dev/null 2>&1
claude plugin install hook-a@poc-hook >/dev/null 2>&1
[[ "$(installed hook-a)" == 1 ]] || fail "precondition: hook-a installed"
[[ "$(installed hook-b)" == 0 ]] || fail "precondition: hook-b absent"

# F1/F3/F4: session 1 -- a's hook fires without auth, detects b missing, installs it
session
grep -q 'status=missing' "$POC_MARKER_DIR/hook-a.ensure-dep" || fail "F3: hook-a did not detect missing dep"
[[ "$(installed hook-b)" == 1 ]] || fail "F4: hook-b not installed by hook"
pass "F1/F3/F4: hook fired unauthenticated, detected and installed hook-b"

# F5: session 2 -- b's hook is active now and installs c
session
grep -q 'status=present' "$POC_MARKER_DIR/hook-a.ensure-dep" || fail "F5: hook-a should see b present"
grep -q 'status=missing' "$POC_MARKER_DIR/hook-b.ensure-dep" || fail "F5: hook-b hook did not fire in session 2"
[[ "$(installed hook-c)" == 1 ]] || fail "F5: hook-c not installed in session 2"
pass "F5: transitive dependency resolved one level per session"

# F5: session 3 -- chain complete, leaf hook fires
session
grep -q 'status=present' "$POC_MARKER_DIR/hook-b.ensure-dep" || fail "F5: hook-b should see c present"
[[ -f "$POC_MARKER_DIR/hook-c.sessionstart" ]] || fail "F5: hook-c hook did not fire in session 3"
pass "F5: full chain active in session 3"

# F6: update detection + apply (bump hook-c in the marketplace copy)
node -e "
const fs = require('fs')
for (const f of ['$Work/marketplace/.claude-plugin/marketplace.json', '$Work/marketplace/plugins/hook-c/.claude-plugin/plugin.json']) {
  fs.writeFileSync(f, fs.readFileSync(f, 'utf8').replaceAll('\"version\": \"0.1.0\"', '\"version\": \"0.2.0\"'))
}"
claude plugin list --json 2>/dev/null | grep -A1 '"id": "hook-c@poc-hook"' | grep -q '"version": "0.1.0"' \
  || fail "F6: installed version should still be 0.1.0 before update"
claude plugin update hook-c@poc-hook >/dev/null 2>&1 || fail "F6: plugin update failed"
claude plugin list --json 2>/dev/null | grep -A1 '"id": "hook-c@poc-hook"' | grep -q '"version": "0.2.0"' \
  || fail "F6: installed version should be 0.2.0 after update"
pass "F6: update detected via version diff and applied via plugin update"

# M1-M3: MCP existence, health probe, and login presence checks from a hook
claude plugin install hook-mcp@poc-hook >/dev/null 2>&1
session
mcp_marker="$POC_MARKER_DIR/hook-mcp.check"
grep -q 'env_check POC_REQUIRED_TOKEN=MISSING' "$mcp_marker" || fail "M3: env presence check missing"
grep -q '"mcpServers"' "$mcp_marker" || fail "M1: plugin list --json did not expose MCP config"
grep -q 'plugin:hook-mcp:poc-http-unreachable' "$mcp_marker" || fail "M2: nested mcp list missed plugin-scoped server"
grep -q 'Failed to connect' "$mcp_marker" || fail "M2: health probe did not report the unreachable server"
pass "M1-M3: MCP config, plugin-scoped health probe, and env presence check visible to the hook"

printf 'all findings verified\n' >&2
