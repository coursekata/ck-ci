load helper

D=sha256:$(printf '%064x' 1)
C=sha256:$(printf '%064x' 2)

setup() {
  fresh_state
  export CANDIDATE=r.example/candidate LAYOUT=/l/image DIGEST=$D CACHE_LAYOUT=/l/cache CACHE_DIGEST=$C CACHE_TAG=cache-7-1
}

@test "pushes the image untagged and the cache under its run's tag, both from their layouts" {
  run "$SCRIPTS/push.sh"
  assert_success
  run calls
  assert_line "docker buildx imagetools create --prefer-index=false --tag r.example/candidate@$D oci-layout:///l/image@$D"
  assert_line "docker buildx imagetools create --prefer-index=false --tag r.example/candidate:cache-7-1 oci-layout:///l/cache@$C"
}

@test "a failed image push stops before the cache" {
  echo 1 >"$FAKE_STATE/create-status"
  run "$SCRIPTS/push.sh"
  assert_failure
  run calls
  refute_line --partial "cache-7-1"
}
