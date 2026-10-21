load helper

A=sha256:$(printf '%064x' 1)
B=sha256:$(printf '%064x' 2)

setup() {
  fresh_state
  export IMAGE_BUILD_BAKE_FILE=docker-bake.hcl IMAGE_BUILD_TEST=app-test IMAGE_BUILD_STAGE=runtime IMAGE_BUILD_LAYOUT=/tmp/layout IMAGE_BUILD_DIGEST=$A
}

# log <line...>: the fake bake's build log.
log() { printf '%s\n' "$@" >"$FAKE_STATE/bake-log"; }

@test "builds the tests on the built image, running every step and exporting nothing" {
  log "#3 [context runtime] load from oci-layout:///tmp/layout@$A" "#3 DONE"
  run "$SCRIPTS/run-tests.sh"
  assert_success
  assert_equal "$(calls)" "docker buildx bake -f docker-bake.hcl --progress=plain --allow fs.read=/tmp/layout --set app-test.contexts.runtime=oci-layout:///tmp/layout@$A --set app-test.no-cache=true --set app-test.output=type=cacheonly app-test"
}

@test "a test stage that never used the image fails" {
  log "#3 [test 1/2] FROM busybox" "#3 DONE"
  run "$SCRIPTS/run-tests.sh"
  assert_failure
  assert_output --partial "::error::app-test never built on the image: its stage does not build FROM runtime, so its tests ran on something else."
}

@test "a stage loaded from another image's digest fails" {
  log "#3 [context runtime] load from oci-layout:///tmp/layout@$B" "#3 DONE"
  run "$SCRIPTS/run-tests.sh"
  assert_failure
  assert_output --partial "::error::app-test never built on the image"
}

@test "failing tests fail" {
  log "#3 [context runtime] load from oci-layout:///tmp/layout@$A"
  echo 1 >"$FAKE_STATE/bake-status"
  run "$SCRIPTS/run-tests.sh"
  assert_failure
  refute_output --partial "never built on the image"
}
