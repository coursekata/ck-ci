#!/usr/bin/env bash
# Builds the test target with the built image, an OCI layout at LAYOUT, swapped in for the stage it
# builds FROM, so the tests run on that image whatever the test target's settings. no-cache runs
# every test step, and the log check fails a test stage that never used the image. Bake reads
# nothing outside the bake file's directory unless allowed, so the layout is allowed by path.
# The env names carry a prefix because bake reads its variables from the environment: a bake file
# that declares one named TARGET would otherwise build what this script never checked.
# env: IMAGE_BUILD_BAKE_FILE, IMAGE_BUILD_TEST, IMAGE_BUILD_STAGE, IMAGE_BUILD_LAYOUT, IMAGE_BUILD_DIGEST
set -euo pipefail

log=$(mktemp)
docker buildx bake -f "$IMAGE_BUILD_BAKE_FILE" --progress=plain --allow "fs.read=$IMAGE_BUILD_LAYOUT" \
  --set "$IMAGE_BUILD_TEST.contexts.$IMAGE_BUILD_STAGE=oci-layout://$IMAGE_BUILD_LAYOUT@$IMAGE_BUILD_DIGEST" \
  --set "$IMAGE_BUILD_TEST.no-cache=true" --set "$IMAGE_BUILD_TEST.output=type=cacheonly" \
  "$IMAGE_BUILD_TEST" 2>&1 | tee "$log"
if ! grep -F "[context $IMAGE_BUILD_STAGE]" "$log" | grep -qF "$IMAGE_BUILD_DIGEST"; then
  echo "::error::$IMAGE_BUILD_TEST never built on the image: its stage does not build FROM $IMAGE_BUILD_STAGE, so its tests ran on something else."
  exit 1
fi
