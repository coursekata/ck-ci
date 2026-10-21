#!/usr/bin/env bash
# Outputs the cache that CACHE's current tag names, as a cache-from pinned by digest, so the build
# and the push read the same cache. With no cache yet, the build starts cold.
# env: CACHE
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

d=$("$here/digest-of.sh" "$CACHE:current")
if [ -n "$d" ]; then
  echo "from=type=registry,ref=$CACHE@$d" >>"$GITHUB_OUTPUT"
else
  echo "::notice::No cache at $CACHE:current yet, so this build starts cold."
fi
