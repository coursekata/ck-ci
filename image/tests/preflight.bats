load helper

setup() {
  fresh_state
  export IMAGE_BUILD_BAKE_FILE=docker-bake.hcl IMAGE_BUILD_TARGET=app IMAGE_BUILD_TEST=app-test
}

# definition <image target json> <test target json>
definition() { bake_prints "{\"target\": {\"app\": $1, \"app-test\": $2}}"; }

@test "outputs the image's stage and its platforms, sorted" {
  definition '{"target": "runtime", "platforms": ["linux/arm64", "linux/amd64"]}' '{"target": "test", "platforms": ["linux/amd64", "linux/arm64"]}'
  run "$SCRIPTS/preflight.sh"
  assert_success
  assert_equal "$(step_output stage)" runtime
  assert_equal "$(step_output platforms)" '["linux/amd64","linux/arm64"]'
  assert_equal "$(calls)" "docker buildx bake -f docker-bake.hcl --print app app-test"
}

@test "an image target that names no stage fails" {
  definition '{}' '{"target": "test"}'
  run "$SCRIPTS/preflight.sh"
  assert_failure
  assert_output --partial "::error::The app's bake target \`app\` names no stage to build to."
}

@test "a test target that names no stage fails" {
  definition '{"target": "runtime"}' '{}'
  run "$SCRIPTS/preflight.sh"
  assert_failure
  assert_output --partial "::error::The test bake target \`app-test\` names no stage to build to."
}

@test "a test target that builds the image's own stage fails" {
  definition '{"target": "runtime"}' '{"target": "runtime"}'
  run "$SCRIPTS/preflight.sh"
  assert_failure
  assert_output --partial "::error::The test bake target \`app-test\` builds to the same stage as the app's bake target \`app\`."
}

@test "a platform the image ships but its tests do not build fails" {
  definition '{"target": "runtime", "platforms": ["linux/amd64", "linux/arm64"]}' '{"target": "test", "platforms": ["linux/amd64"]}'
  run "$SCRIPTS/preflight.sh"
  assert_failure
  assert_output --partial "ships [\"linux/amd64\",\"linux/arm64\"], but the test bake target \`app-test\` builds for [\"linux/amd64\"]."
}

@test "an image target that sets its own cache fails" {
  definition '{"target": "runtime", "cache-from": ["type=gha"]}' '{"target": "test"}'
  run "$SCRIPTS/preflight.sh"
  assert_failure
  assert_output "::error::The bake target \`app\` sets cache-from. build-action sets every cache and output itself, so a build reads only the release cache and nothing leaves the runner before push-action: remove cache-from, cache-to and output from the bake file's image and test targets."
}

@test "a test target that sets its own output fails" {
  definition '{"target": "runtime"}' '{"target": "test", "output": ["type=registry"]}'
  run "$SCRIPTS/preflight.sh"
  assert_failure
  assert_output --partial "::error::The bake target \`app-test\` sets output."
}

@test "a platform written with its default variant is the same platform" {
  definition '{"target": "runtime", "platforms": ["linux/arm64/v8", "linux/amd64/v1"]}' '{"target": "test", "platforms": ["linux/amd64", "linux/arm64"]}'
  run "$SCRIPTS/preflight.sh"
  assert_success
  assert_equal "$(step_output platforms)" '["linux/amd64","linux/arm64"]'
}
