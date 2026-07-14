#!/usr/bin/env bash
# Dependency hook (Copilot): verify DEP is installed; if not, install it from this marketplace.
set -uo pipefail
readonly Dep="hook-c"
readonly Self="hook-b"
dir="${POC_MARKER_DIR:-/tmp}"
mkdir -p "$dir"
log="$dir/${Self}.ensure-dep"
{
  if copilot plugin list 2>/dev/null | grep -q "$Dep"; then
    printf 'dep=%s status=present\n' "$Dep"
  else
    printf 'dep=%s status=missing -- installing\n' "$Dep"
    if copilot plugin install "${Dep}@poc-hook" >>"$log.install" 2>&1; then
      printf 'install=ok\n'
    else
      printf 'install=FAILED rc=%s\n' "$?"
    fi
  fi
} >> "$log" 2>&1
exit 0
