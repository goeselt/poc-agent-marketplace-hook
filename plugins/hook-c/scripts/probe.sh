#!/usr/bin/env bash
set -uo pipefail
printf 'variant=git-v2 plugin_root=%s\n' "${CLAUDE_PLUGIN_ROOT:-<unset>}" > "${POC_MARKER_DIR:-/tmp}/hook-c.sessionstart"
exit 0
