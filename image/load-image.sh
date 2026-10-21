#!/usr/bin/env bash
# Loads TARGET for this runner's platform into Docker from the build's cache, with the build's
# labels, as image-build/<target>:candidate for the caller's checks, and outputs its name. An image
# that does not ship this runner's platform loads nothing, warns, and outputs the name empty.
# PLATFORMS is the JSON list the image ships; an empty list means the builder's own. The load is a
# second export, so its layers must be the tested layout's for this platform, or the checks would run
# on other bytes than the ones pushed.
# The env names carry a prefix because bake reads its variables from the environment: a bake file
# that declares one named TARGET would otherwise build what this script never checked.
# env: IMAGE_BUILD_BAKE_FILE, IMAGE_BUILD_LABELS_FILE, IMAGE_BUILD_TARGET, IMAGE_BUILD_PLATFORMS, IMAGE_BUILD_LAYOUT
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

platform=$(docker version --format '{{.Server.Os}}/{{.Server.Arch}}')
if ! jq -e --arg p "$platform" 'length == 0 or any(.[]; . == $p)' <<<"$IMAGE_BUILD_PLATFORMS" >/dev/null; then
  echo "::warning::$IMAGE_BUILD_TARGET ships $IMAGE_BUILD_PLATFORMS, not this runner's $platform, so no image was loaded for checks."
  echo "image=" >>"$GITHUB_OUTPUT"
  exit 0
fi
image="image-build/$IMAGE_BUILD_TARGET:candidate"
docker buildx bake -f "$IMAGE_BUILD_BAKE_FILE" -f "$IMAGE_BUILD_LABELS_FILE" --set "$IMAGE_BUILD_TARGET.platform=$platform" --set "$IMAGE_BUILD_TARGET.output=type=docker,name=$image" "$IMAGE_BUILD_TARGET"

blob() { cat "$IMAGE_BUILD_LAYOUT/blobs/sha256/${1#sha256:}"; }
entry=$(jq -c '.manifests[0]' "$IMAGE_BUILD_LAYOUT/index.json")
manifest=$(jq -r .digest <<<"$entry")
if [ "$(jq -r .mediaType <<<"$entry")" = application/vnd.oci.image.index.v1+json ]; then
  manifest=$(blob "$manifest" | jq -L "$here" -r --arg p "$platform" \
    'include "platform"; [.manifests[] | select((.platform.os + "/" + .platform.architecture + (if .platform.variant then "/" + .platform.variant else "" end) | norm) == $p)][0].digest')
fi
tested=$(blob "$(blob "$manifest" | jq -r .config.digest)" | jq -c .rootfs.diff_ids)
loaded=$(docker image inspect --format '{{json .RootFS.Layers}}' "$image" | jq -c .)
if [ "$loaded" != "$tested" ]; then
  echo "::error::The image loaded for checks has layers $loaded, not the tested build's $tested for $platform, so checks on it would not cover the bytes pushed."
  exit 1
fi
echo "image=$image" >>"$GITHUB_OUTPUT"
