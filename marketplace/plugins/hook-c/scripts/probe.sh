#!/usr/bin/env bash
# Probe: record that the hook fired, plus everything the hook can see.
set -uo pipefail
dir="${POC_MARKER_DIR:-/tmp}"
mkdir -p "$dir"
{
  printf 'fired_at=%s\n' "$(date -Is)"
  printf 'pwd=%s\n' "$PWD"
  printf 'plugin_root=%s\n' "${CLAUDE_PLUGIN_ROOT:-<unset>}"
  printf 'config_dir=%s\n' "${CLAUDE_CONFIG_DIR:-<unset>}"
  printf '%s\n' '--- stdin ---'
  cat
} > "$dir/hook-c.sessionstart" 2>&1
exit 0
