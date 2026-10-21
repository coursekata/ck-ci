load helper

# blob <json>: writes json to the layout as a blob and prints its digest.
blob() {
  local d
  d=$(printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1)
  printf '%s' "$1" >"$IMAGE_BUILD_LAYOUT/blobs/sha256/$d"
  echo "sha256:$d"
}

# image_manifest <diff id>: a manifest whose config has that one layer.
image_manifest() { blob "{\"config\":{\"digest\":\"$(blob "{\"rootfs\":{\"diff_ids\":[\"$1\"]}}")\"}}"; }

# layout <index entry json>: the layout's index.json names that one entry.
layout() { printf '{"manifests":[%s]}' "$1" >"$IMAGE_BUILD_LAYOUT/index.json"; }

# multi_platform_layout: amd64 has layer sha256:amd, arm64 sha256:arm.
multi_platform_layout() {
  local idx
  idx=$(blob "{\"manifests\":[{\"digest\":\"$(image_manifest sha256:amd)\",\"platform\":{\"os\":\"linux\",\"architecture\":\"amd64\"}},{\"digest\":\"$(image_manifest sha256:arm)\",\"platform\":{\"os\":\"linux\",\"architecture\":\"arm64\"}}]}")
  layout "{\"mediaType\":\"application/vnd.oci.image.index.v1+json\",\"digest\":\"$idx\"}"
}

setup() {
  fresh_state
  echo linux/arm64 >"$FAKE_STATE/platform"
  export IMAGE_BUILD_LAYOUT="$BATS_TEST_TMPDIR/layout"
  mkdir -p "$IMAGE_BUILD_LAYOUT/blobs/sha256"
  multi_platform_layout
  echo '["sha256:arm"]' >"$FAKE_STATE/loaded-layers"
  export IMAGE_BUILD_BAKE_FILE=docker-bake.hcl IMAGE_BUILD_TARGET=app IMAGE_BUILD_LABELS_FILE=/tmp/labels.json
}

@test "loads the image for the runner's platform, with the build's labels, and outputs its name" {
  export IMAGE_BUILD_PLATFORMS='["linux/amd64","linux/arm64"]'
  run "$SCRIPTS/load-image.sh"
  assert_success
  assert_equal "$(step_output image)" "image-build/app:candidate"
  run calls
  assert_line "docker buildx bake -f docker-bake.hcl -f /tmp/labels.json --set app.platform=linux/arm64 --set app.output=type=docker,name=image-build/app:candidate app"
}

@test "an image that names no platforms is loaded for the runner's" {
  export IMAGE_BUILD_PLATFORMS='[]'
  layout "{\"mediaType\":\"application/vnd.oci.image.manifest.v1+json\",\"digest\":\"$(image_manifest sha256:arm)\"}"
  run "$SCRIPTS/load-image.sh"
  assert_success
  assert_equal "$(step_output image)" "image-build/app:candidate"
}

@test "an image that does not ship the runner's platform loads nothing and outputs no name" {
  export IMAGE_BUILD_PLATFORMS='["linux/amd64"]'
  run "$SCRIPTS/load-image.sh"
  assert_success
  assert_output '::warning::app ships ["linux/amd64"], not this runner'"'"'s linux/arm64, so no image was loaded for checks.'
  assert_equal "$(step_output image)" ""
  run calls
  refute_line --partial "buildx bake"
}

@test "a loaded image whose layers are not the tested build's fails" {
  export IMAGE_BUILD_PLATFORMS='["linux/amd64","linux/arm64"]'
  echo '["sha256:other"]' >"$FAKE_STATE/loaded-layers"
  run "$SCRIPTS/load-image.sh"
  assert_failure
  assert_output --partial "::error::The image loaded for checks has layers [\"sha256:other\"], not the tested build's [\"sha256:arm\"] for linux/arm64, so checks on it would not cover the bytes pushed."
  assert_equal "$(step_output image)" ""
}

@test "an index entry written with its platform's default variant is the runner's platform" {
  export IMAGE_BUILD_PLATFORMS='["linux/arm64"]'
  local idx
  idx=$(blob "{\"manifests\":[{\"digest\":\"$(image_manifest sha256:arm)\",\"platform\":{\"os\":\"linux\",\"architecture\":\"arm64\",\"variant\":\"v8\"}}]}")
  layout "{\"mediaType\":\"application/vnd.oci.image.index.v1+json\",\"digest\":\"$idx\"}"
  run "$SCRIPTS/load-image.sh"
  assert_success
  assert_equal "$(step_output image)" "image-build/app:candidate"
}
