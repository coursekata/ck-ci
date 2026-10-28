#!/usr/bin/env bash
# Checks that the image and test bake targets can be built and tested as build-action does, before
# anything builds, and outputs the image's stage and platforms for the steps after it. preflight.jq
# decides from the bake definition.
# The env names carry a prefix because bake reads its variables from the environment: a bake file
# that declares one named TARGET would otherwise build what this script never checked.
# env: IMAGE_BUILD_BAKE_FILE, IMAGE_BUILD_TARGET, IMAGE_BUILD_TEST
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

result=$(docker buildx bake -f "$IMAGE_BUILD_BAKE_FILE" --print "$IMAGE_BUILD_TARGET" "$IMAGE_BUILD_TEST" |
  jq -L "$here" -c --arg i "$IMAGE_BUILD_TARGET" --arg t "$IMAGE_BUILD_TEST" 'include "preflight"; check($i; $t)')
if error=$(jq -er .error <<<"$result"); then
  echo "::error::$error"
  exit 1
fi
{
  echo "stage=$(jq -r .stage <<<"$result")"
  echo "platforms=$(jq -c .platforms <<<"$result")"
} >>"$GITHUB_OUTPUT"
