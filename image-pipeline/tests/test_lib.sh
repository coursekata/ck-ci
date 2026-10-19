#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=../lib.sh
. "$PIPELINE_DIR/lib.sh"

D1=sha256:$(printf '%064x' 1)

# fn <function> <args...>: runs a lib.sh function in a child bash, so a die cannot end the test.
fn() { run bash -c '. "$1"; shift; "$@"' _ "$PIPELINE_DIR/lib.sh" "$@"; }

test_digest_of_asks_buildx_for_the_digest_of_a_present_reference() {
  fresh_state
  registry_has r.example/app:t "$D1"
  fn digest_of r.example/app:t
  assert_status 0
  assert_eq "$D1" "$OUT"
  assert_contains "$(calls)" "docker buildx imagetools inspect --format {{json .Manifest}} r.example/app:t"
}

test_digest_of_reads_not_found_as_absent() {
  fresh_state
  registry_fails r.example/app:missing "ERROR: r.example/app:missing: not found"
  fn digest_of r.example/app:missing
  assert_status 3
  assert_eq "" "$OUT"
}

test_digest_of_stops_on_a_denied_lookup() {
  fresh_state
  registry_fails r.example/app:t "ERROR: unexpected status from HEAD request to https://r.example/v2/app/manifests/t: 403 Forbidden"
  fn digest_of r.example/app:t
  assert_status 1
  assert_contains "$ERR" "403 Forbidden"
}

test_digest_of_refuses_an_answer_that_is_not_a_digest() {
  fresh_state
  registry_has r.example/app:t not-a-digest
  fn digest_of r.example/app:t
  assert_status 1
}

test_bake_clean_keeps_the_jobs_credentials_away_from_bake() {
  fresh_state
  export AWS_SECRET_ACCESS_KEY=secret BUILDX_BUILDER=pipeline
  fn bake_clean app
  assert_status 0
  assert_contains "$(calls)" "docker buildx bake app"
  assert_contains "$(calls)" "bake-env aws=[] builder=[pipeline] lookup=[1]"
}

test_bake_clean_passes_the_build_secret_under_the_callers_name() {
  fresh_state
  export BUILD_SECRET_ENV=GITHUB_TOKEN BUILD_SECRET=s3cret
  fn bake_clean app
  assert_status 0
  assert_contains "$(calls)" "token=[s3cret]"
}

test_bake_clean_passes_no_secret_the_caller_did_not_name() {
  fresh_state
  export GITHUB_TOKEN=the-jobs-token BUILD_SECRET=s3cret
  fn bake_clean app
  assert_status 0
  assert_contains "$(calls)" "token=[]"
}

test_bake_clean_passes_an_empty_secret_when_the_value_is_missing() {
  fresh_state
  export BUILD_SECRET_ENV=GITHUB_TOKEN
  unset BUILD_SECRET
  fn bake_clean app
  assert_status 0
  assert_contains "$(calls)" "token=[]"
}

test_bake_clean_keeps_its_own_path_when_the_caller_names_path() {
  fresh_state
  export BUILD_SECRET_ENV=PATH BUILD_SECRET=/nowhere
  fn bake_clean app
  assert_status 0
  assert_contains "$(calls)" "docker buildx bake app"
}

run_tests
