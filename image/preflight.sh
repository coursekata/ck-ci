#!/usr/bin/env bash
# Checks that the image and test bake targets can be built and tested as build-action does, before
# anything builds, and outputs the image's stage and platforms for the steps after it.
# The env names carry a prefix because bake reads its variables from the environment: a bake file
# that declares one named TARGET would otherwise build what this script never checked.
# env: IMAGE_BUILD_BAKE_FILE, IMAGE_BUILD_TARGET, IMAGE_BUILD_TEST
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

definition=$(docker buildx bake -f "$IMAGE_BUILD_BAKE_FILE" --print "$IMAGE_BUILD_TARGET" "$IMAGE_BUILD_TEST")
image_stage=$(jq -r --arg t "$IMAGE_BUILD_TARGET" '.target[$t].target // ""' <<<"$definition")
test_stage=$(jq -r --arg t "$IMAGE_BUILD_TEST" '.target[$t].target // ""' <<<"$definition")
image_platforms=$(jq -L "$here" -c --arg t "$IMAGE_BUILD_TARGET" 'include "platform"; .target[$t].platforms // [] | map(norm) | unique' <<<"$definition")
test_platforms=$(jq -L "$here" -c --arg t "$IMAGE_BUILD_TEST" 'include "platform"; .target[$t].platforms // [] | map(norm) | unique' <<<"$definition")

# build-action sets every cache and output, so the bake file's own would bypass the release cache or
# send bytes out before the checks.
for t in "$IMAGE_BUILD_TARGET" "$IMAGE_BUILD_TEST"; do
  for key in cache-from cache-to output; do
    if jq -e --arg t "$t" --arg k "$key" '.target[$t][$k] // [] | length > 0' <<<"$definition" >/dev/null; then
      echo "::error::The bake target \`$t\` sets $key. build-action sets every cache and output itself, so a build reads only the release cache and nothing leaves the runner before push-action: remove cache-from, cache-to and output from the bake file's image and test targets."
      exit 1
    fi
  done
done

# The tests run with the built image swapped in for this stage, so the target must name it.
if [ -z "$image_stage" ]; then
  echo "::error::The app's bake target \`$IMAGE_BUILD_TARGET\` names no stage to build to. Give it target = \"<stage>\", so the test bake target \`$IMAGE_BUILD_TEST\` can build from it."
  exit 1
fi

# A test target with no stage of its own would rebuild the image and run no tests.
if [ -z "$test_stage" ]; then
  echo "::error::The test bake target \`$IMAGE_BUILD_TEST\` names no stage to build to. A test layer is required, and it must build from the stage that the \`$IMAGE_BUILD_TARGET\` target builds to."
  exit 1
fi
if [ "$test_stage" = "$image_stage" ]; then
  echo "::error::The test bake target \`$IMAGE_BUILD_TEST\` builds to the same stage as the app's bake target \`$IMAGE_BUILD_TARGET\`. A test layer is required, and it must build from the stage that the \`$IMAGE_BUILD_TARGET\` target builds to."
  exit 1
fi

# A platform the image ships but its tests don't build would ship untested.
if [ "$image_platforms" != "$test_platforms" ]; then
  echo "::error::The app's bake target \`$IMAGE_BUILD_TARGET\` ships $image_platforms, but the test bake target \`$IMAGE_BUILD_TEST\` builds for $test_platforms. Every platform the image ships must be tested."
  exit 1
fi

{
  echo "stage=$image_stage"
  echo "platforms=$image_platforms"
} >>"$GITHUB_OUTPUT"
