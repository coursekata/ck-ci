#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CAND=r.example/c
REL=r.example/r
CACHE=r.example/k
SHA=$(printf '%040x' 1)
RUN=4242
D1=sha256:$(printf '%064x' 1)
C1=sha256:$(printf '%064x' 12)
D9=sha256:$(printf '%064x' 9)
C9=sha256:$(printf '%064x' 19)
SHA_TAG="$REL:sha-$SHA"
RUN_TAG="$REL:run-$RUN"
CACHE_TAG="$CACHE:current"

setup() {
  fresh_state
  W=$(mktemp -d)
  jq -nc --arg c "$CAND" --arg r "$REL" --arg k "$CACHE" \
    '[{target: "app", test: "app-test", replaces: "runtime", candidate: $c, release: $r, cache: $k}]' >"$W/targets.json"
  built '.'
}

# built <jq edit>: the build job's output for this run.
built() {
  jq -n --arg d "$D1" --arg c "$C1" '{fresh: false, targets: {app: {digest: $d, cache_digest: $c}}}' |
    jq "$1" >"$W/build.json"
}

candidates_present() {
  registry_has "$CAND@$D1" "$D1"
  registry_has "$CAND@$C1" "$C1"
}

release() { run "$PIPELINE_DIR/release-target.sh" "$W/targets.json" "$W/build.json" app "${1:-$SHA}" "${2:-$RUN}"; }
copies() { calls | grep -c '^docker buildx imagetools create' || true; }
COPY="docker buildx imagetools create --prefer-index=false --tag"

test_copies_the_tested_image_to_its_commit_and_run_tags_and_its_cache_to_the_cache_tag() {
  setup
  candidates_present
  release
  assert_status 0
  assert_eq "$D1" "$(jq -r .digest <<<"$OUT")"
  assert_eq '["image","run","cache"]' "$(jq -c .copied <<<"$OUT")"
  assert_contains "$(calls)" "$COPY $SHA_TAG $CAND@$D1"
  assert_contains "$(calls)" "$COPY $RUN_TAG $CAND@$D1"
  assert_contains "$(calls)" "$COPY $CACHE_TAG $CAND@$C1"
}

test_moves_the_cache_tag_off_an_earlier_cache() {
  setup
  candidates_present
  registry_has "$CACHE_TAG" "$C9"
  release
  assert_status 0
  assert_contains "$(calls)" "$COPY $CACHE_TAG $CAND@$C1"
}

test_a_rerun_of_failed_jobs_finishes_what_the_first_attempt_left() {
  setup
  candidates_present
  registry_has "$SHA_TAG" "$D1"
  release
  assert_status 0
  assert_eq "$D1" "$(jq -r .digest <<<"$OUT")"
  assert_eq '["run","cache"]' "$(jq -c .copied <<<"$OUT")"
  assert_eq 2 "$(copies)"
}

test_a_rerun_after_a_complete_release_copies_nothing() {
  setup
  candidates_present
  registry_has "$SHA_TAG" "$D1"
  registry_has "$RUN_TAG" "$D1"
  registry_has "$CACHE_TAG" "$C1"
  release
  assert_status 0
  assert_eq '[]' "$(jq -c .copied <<<"$OUT")"
  assert_eq 0 "$(copies)"
}

test_a_full_rerun_leaves_the_first_release_and_the_cache_standing() {
  setup
  candidates_present
  registry_has "$SHA_TAG" "$D9"
  registry_has "$CACHE_TAG" "$C9"
  release
  assert_status 0
  assert_eq "$D9" "$(jq -r .digest <<<"$OUT")" "the commit's release is the first one"
  assert_contains "$(jq -r .note <<<"$OUT")" "and that release stands"
  assert_eq 0 "$(copies)"
}

test_a_build_without_the_cache_of_a_released_commit_replaces_only_the_cache() {
  setup
  built '.fresh = true'
  candidates_present
  registry_has "$SHA_TAG" "$D9"
  registry_has "$CACHE_TAG" "$C9"
  release
  assert_status 0
  assert_eq "$D9" "$(jq -r .digest <<<"$OUT")" "the commit's release is the first one"
  assert_eq '["cache"]' "$(jq -c .copied <<<"$OUT")"
  assert_contains "$(calls)" "$COPY $CACHE_TAG $CAND@$C1"
  assert_eq 1 "$(copies)"
  assert_contains "$(jq -r .note <<<"$OUT")" "the next build"
}

test_a_build_without_the_cache_of_an_unreleased_commit_releases_it() {
  setup
  built '.fresh = true'
  candidates_present
  release
  assert_status 0
  assert_eq "$D1" "$(jq -r .digest <<<"$OUT")"
  assert_eq '["image","run","cache"]' "$(jq -c .copied <<<"$OUT")"
}

test_a_build_without_the_cache_copies_nothing_when_its_cache_is_gone() {
  setup
  built '.fresh = true'
  registry_has "$CAND@$D1" "$D1"
  registry_has "$SHA_TAG" "$D9"
  release
  assert_status 1
  assert_contains "$ERR" "the run's cache $CAND@$C1 is gone"
  assert_eq 0 "$(copies)"
}

test_a_build_without_the_cache_fails_when_the_cache_lands_on_another_digest() {
  setup
  built '.fresh = true'
  candidates_present
  registry_has "$SHA_TAG" "$D9"
  echo "$C9" >"$FAKE_STATE/copy-lands-as"
  release
  assert_status 1
  assert_contains "$ERR" "$CACHE_TAG reads back as $C9"
}

test_a_full_rerun_of_a_run_by_hand_that_released_replaces_only_the_cache() {
  setup
  built '.fresh = true'
  candidates_present
  registry_has "$SHA_TAG" "$D9"
  registry_has "$RUN_TAG" "$D9"
  registry_has "$CACHE_TAG" "$C9"
  release
  assert_status 0
  assert_eq '["cache"]' "$(jq -c .copied <<<"$OUT")"
  assert_eq 1 "$(copies)"
}

test_a_build_without_the_cache_copies_nothing_when_the_cache_is_already_its_own() {
  setup
  built '.fresh = true'
  candidates_present
  registry_has "$SHA_TAG" "$D9"
  registry_has "$CACHE_TAG" "$C1"
  release
  assert_status 0
  assert_eq '[]' "$(jq -c .copied <<<"$OUT")"
  assert_eq 0 "$(copies)"
}

test_fails_when_the_tested_image_is_gone() {
  setup
  registry_has "$CAND@$C1" "$C1"
  release
  assert_status 1
  assert_contains "$ERR" "the tested image $CAND@$D1 is gone"
  assert_eq 0 "$(copies)"
}

test_fails_before_copying_when_the_cache_is_gone() {
  setup
  registry_has "$CAND@$D1" "$D1"
  release
  assert_status 1
  assert_contains "$ERR" "the run's cache $CAND@$C1 is gone"
  assert_eq 0 "$(copies)"
}

test_fails_when_a_copy_lands_on_another_digest() {
  setup
  candidates_present
  echo "$D9" >"$FAKE_STATE/copy-lands-as"
  release
  assert_status 1
  assert_contains "$ERR" "reads back as $D9"
}

test_stops_on_a_registry_error_without_copying() {
  setup
  candidates_present
  registry_fails "$SHA_TAG" "ERROR: unexpected status from HEAD request to https://r.example/v2/r/manifests/x: 403 Forbidden"
  release
  assert_status 1
  assert_contains "$ERR" "could not read $SHA_TAG"
  assert_eq 0 "$(copies)"
}

test_stops_when_the_run_tag_names_another_image() {
  setup
  candidates_present
  registry_has "$RUN_TAG" "$D9"
  release
  assert_status 1
  assert_contains "$ERR" "$RUN_TAG already names $D9"
  assert_eq 0 "$(copies)"
}

test_refuses_a_short_commit_sha() {
  setup
  release abc1234
  assert_status 1
  assert_contains "$ERR" "full commit SHA"
}

test_refuses_a_run_id_that_is_not_a_number() {
  setup
  release "$SHA" 12a
  assert_status 1
  assert_contains "$ERR" "run id must be a number"
}

test_refuses_a_build_that_does_not_say_whether_it_imported_the_cache() {
  setup
  built 'del(.fresh)'
  release
  assert_status 1
  assert_contains "$ERR" "the build's fresh 'null' is not true or false"
}

test_refuses_a_malformed_cache_digest() {
  setup
  built '.targets.app.cache_digest = "sha256:zz"'
  release
  assert_status 1
  assert_contains "$ERR" "cache digest"
}

test_fails_when_the_builds_targets_are_not_the_configured_ones() {
  setup
  built '.targets.worker = .targets.app'
  release
  assert_status 1
  assert_contains "$ERR" "are not the configured targets"
}

run_tests
