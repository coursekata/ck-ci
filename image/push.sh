#!/usr/bin/env bash
# Pushes the tested image and its build cache from their OCI layouts to CANDIDATE, byte for byte:
# the image by digest and untagged, the cache under CACHE_TAG, since each cache push needs a tag of
# its own. A digest a layout does not hold fails and pushes nothing.
# env: CANDIDATE, LAYOUT, DIGEST, CACHE_LAYOUT, CACHE_DIGEST, CACHE_TAG
set -euo pipefail

docker buildx imagetools create --prefer-index=false --tag "$CANDIDATE@$DIGEST" "oci-layout://$LAYOUT@$DIGEST"
docker buildx imagetools create --prefer-index=false --tag "$CANDIDATE:$CACHE_TAG" "oci-layout://$CACHE_LAYOUT@$CACHE_DIGEST"
