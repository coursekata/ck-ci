load helper

D1=sha256:$(printf '%064x' 1)

setup() {
  fresh_state
  export CACHE=r.example/cache
}

@test "pins the cache that the current tag names, by digest" {
  registry_has r.example/cache:current "$D1"
  run "$SCRIPTS/pin-cache.sh"
  assert_success
  assert_equal "$(step_output from)" "type=registry,ref=r.example/cache@$D1"
}

@test "with no cache yet, the build starts cold with a notice" {
  run "$SCRIPTS/pin-cache.sh"
  assert_success
  assert_equal "$(step_output from)" ""
  assert_output "::notice::No cache at r.example/cache:current yet, so this build starts cold."
}

@test "a denied lookup fails" {
  registry_fails r.example/cache:current "ERROR: 403 Forbidden"
  run "$SCRIPTS/pin-cache.sh"
  assert_failure
  assert_output --partial "::error::Could not read r.example/cache:current."
  assert_equal "$(step_output from)" ""
}
