#!/usr/bin/env bash
# Prints the digest a reference names, or nothing when buildx says it does not exist. buildx says
# the same for a missing repository as for a missing tag, so a misnamed repository reads as empty
# here. Any other answer, such as denied, throttled or unreachable, fails: read as "does not exist",
# it would skip a cache that exists or release over a tag that does.
# usage: digest-of.sh <ref>
set -euo pipefail
ref=$1
err=$(mktemp)
if out=$(docker buildx imagetools inspect --format '{{json .Manifest}}' "$ref" 2>"$err"); then
  digest=$(jq -r '.digest // ""' <<<"$out" 2>/dev/null) || digest=""
  if [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]]; then
    printf '%s\n' "$digest"
    exit 0
  fi
  echo "buildx answered '$out', which names no digest" >&2
elif grep -qF -- "$ref: not found" "$err"; then
  exit 0
else
  cat "$err" >&2
fi
echo "::error::Could not read $ref." >&2
exit 1
