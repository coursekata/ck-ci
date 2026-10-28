#!/usr/bin/env bash
# Runs a crane read, such as `digest <ref>` or `ls <repository>`, and prints its answer, or nothing
# when the registry has no such tag or repository. Any other failure, such as denied, throttled or
# unreachable, fails: read as absent, it would skip a cache that exists or release over a tag that
# does.
# usage: read-registry.sh <crane command> <argument>...
set -euo pipefail
err=$(mktemp)
trap 'rm -f "$err"' EXIT
if crane "$@" 2>"$err"; then
  exit 0
fi
if grep -qE 'MANIFEST_UNKNOWN|NAME_UNKNOWN' "$err"; then
  exit 0
fi
cat "$err" >&2
echo "::error::Could not read ${*: -1}." >&2
exit 1
