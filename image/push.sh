#!/usr/bin/env bash
# Pushes the tested image and its build cache from their OCI layouts to CANDIDATE, byte for byte:
# the image by digest and untagged, the cache under CACHE_TAG, since each cache push needs a tag of
# its own. crane pushes a layout's one manifest whatever its digest, so a layout that holds anything
# but its digest fails first, and nothing is pushed.
# env: CANDIDATE, LAYOUT, DIGEST, CACHE_LAYOUT, CACHE_DIGEST, CACHE_TAG
set -euo pipefail

# holds <layout> <digest>: fails unless the layout holds that one manifest and nothing else.
holds() {
  jq -e --arg d "$2" '[.manifests[].digest] == [$d]' "$1/index.json" >/dev/null 2>&1 || {
    echo "::error::$1 does not hold $2 alone, so nothing was pushed."
    exit 1
  }
}
holds "$LAYOUT" "$DIGEST"
holds "$CACHE_LAYOUT" "$CACHE_DIGEST"
crane push "$LAYOUT" "$CANDIDATE@$DIGEST"
crane push "$CACHE_LAYOUT" "$CANDIDATE:$CACHE_TAG"
