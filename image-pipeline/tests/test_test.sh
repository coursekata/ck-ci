#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

IMG="r.example/c@sha256:$(printf '%064x' 1)"

setup() {
  fresh_state
  W=$(mktemp -d)
  echo '{"target": {}}' >"$W/resolved.json"
}

tst() { run "$PIPELINE_DIR/test.sh" "$W/resolved.json" app-test runtime "${1:-$IMG}" "$W"; }

test_replaces_the_stage_with_the_image_and_reruns_every_test_step() {
  setup
  echo "#4 [context runtime] $IMG" >"$FAKE_STATE/bake-log"
  tst
  assert_status 0
  assert_eq "{\"target\":{\"app-test\":{\"contexts\":{\"runtime\":\"docker-image://$IMG\"},\"no-cache\":true,\"call\":\"build\",\"output\":[\"type=cacheonly\"]}}}" \
    "$(jq -c . "$W/test-overrides.json")"
}

test_fails_when_no_stage_built_on_the_image() {
  setup
  echo "#4 [unrelated 1/2] FROM busybox" >"$FAKE_STATE/bake-log"
  tst
  assert_status 1
  assert_contains "$ERR" "app-test never built on the image under test"
}

test_a_failing_test_fails() {
  setup
  echo 1 >"$FAKE_STATE/bake-status"
  tst
  assert_status 1
  assert_contains "$ERR" "app-test failed on $IMG"
}

test_refuses_an_image_not_named_by_digest() {
  setup
  tst r.example/c:latest
  assert_status 1
  assert_contains "$ERR" "must be named by digest"
}

test_runs_without_the_jobs_credentials() {
  setup
  export AWS_SECRET_ACCESS_KEY=secret
  echo "#4 [context runtime] $IMG" >"$FAKE_STATE/bake-log"
  tst
  assert_status 0
  assert_contains "$(calls)" "bake-env aws=[] builder=[] lookup=[1]"
}

run_tests
