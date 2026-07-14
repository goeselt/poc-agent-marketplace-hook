#!/usr/bin/env bash
# MCP/login probe: what can a hook see about MCP servers and required credentials?
set -uo pipefail
dir="${POC_MARKER_DIR:-/tmp}"
mkdir -p "$dir"
{
  printf 'env_check POC_REQUIRED_TOKEN=%s\n' "$([[ -n "${POC_REQUIRED_TOKEN:-}" ]] && printf present || printf MISSING)"
  printf 'binary_check poc-nonexistent-mcp-server=%s\n' "$(command -v poc-nonexistent-mcp-server >/dev/null && printf present || printf MISSING)"
  printf -- '--- mcp config via plugin list --json ---\n'
  claude plugin list --json 2>/dev/null | grep -E '"id"|"mcpServers"|"type"|"url"|"command"'
  printf -- '--- nested claude mcp list (independent health probe) ---\n'
  timeout 60 claude mcp list 2>&1
  printf 'mcp_list_rc=%s\n' "$?"
} > "$dir/hook-mcp.check" 2>&1
exit 0
