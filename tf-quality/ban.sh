#!/usr/bin/env bash
# Fails on the constructs that turn a plan into arbitrary code execution: an external data source, a
# provisioner, or a provider endpoints override. None has a legitimate use in the org's roots. JSON
# configuration fails outright, since the pattern cannot read it, and so does a file grep cannot read.
set -uo pipefail

json=() files=()
for f in "$@"; do
  case "$f" in
    *.json) json+=("$f") ;;
    *) files+=("$f") ;;
  esac
done

if [ "${#json[@]}" -gt 0 ]; then
  echo "JSON configuration is not allowed, since this check cannot read it:"
  printf '%s\n' "${json[@]}"
  exit 1
fi
[ "${#files[@]}" -gt 0 ] || exit 0

rc=0
hits=$(grep -nHE 'data[[:space:]]+"external"|provisioner[[:space:]]+"|(^|[[:space:]])endpoints[[:space:]]*[={]' \
  -- "${files[@]}") || rc=$?
if [ "$rc" -eq 0 ]; then
  echo "Disallowed plan-time code-execution construct (external data source, provisioner or provider endpoints override):"
  echo "$hits"
  exit 1
elif [ "$rc" -ne 1 ]; then
  echo "grep could not read every file, so the ban cannot pass."
  exit 1
fi
