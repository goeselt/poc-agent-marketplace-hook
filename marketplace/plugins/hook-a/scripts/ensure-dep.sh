#!/usr/bin/env bash
# Dependency hook: verify DEP is installed; if not, install it from this marketplace.
set -uo pipefail
readonly Dep="hook-b"
readonly Self="hook-a"
dir="${POC_MARKER_DIR:-/tmp}"
mkdir -p "$dir"
log="$dir/${Self}.ensure-dep"
{
  printf 'fired_at=%s\n' "$(date -Is)"
  if claude plugin list --json 2>/dev/null | grep -q "\"id\": \"${Dep}@poc-hook\""; then
    printf 'dep=%s status=present\n' "$Dep"
  else
    printf 'dep=%s status=missing -- installing\n' "$Dep"
    if claude plugin install "${Dep}@poc-hook" >>"$log.install" 2>&1; then
      printf 'install=ok\n'
    else
      printf 'install=FAILED rc=%s\n' "$?"
    fi
  fi
} >> "$log" 2>&1
exit 0
