#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CAND=r.example/c
CACHE=r.example/k
D1=sha256:$(printf '%064x' 1)
C1=sha256:$(printf '%064x' 12)
K1=sha256:$(printf '%064x' 21)

setup() {
  fresh_state
  W=$(mktemp -d)
  jq -nc --arg c "$CAND" --arg k "$CACHE" \
    '[{target: "app", test: "app-test", replaces: "runtime", candidate: $c, release: "r.example/r", cache: $k}]' >"$W/targets.json"
  jq -n '{target: {app: {target: "runtime"}, "app-test": {target: "test"}}}' >"$W/resolved.json"
}

# pushed: bake's metadata after a push build: each target's image digest, and its
# cache manifest's descriptor as a JSON string, the way BuildKit reports it.
pushed() {
  jq -n --arg d "$D1" --arg c "$C1" '{app: {
    "containerimage.digest": $d,
    "cache.manifest": ({mediaType: "application/vnd.oci.image.manifest.v1+json", digest: $c, size: 1} | tojson)}}' \
    >"$FAKE_STATE/metadata.json"
}

build() { run "$PIPELINE_DIR/build.sh" "$W/targets.json" "$W/resolved.json" "$1" "${2:-true}" 4242 2 "$W"; }
overrides() { jq -c "$1" "$W/build-overrides.json"; }

test_a_pull_request_pushes_nothing_and_exports_no_cache() {
  setup
  build pr
  assert_status 0
  assert_eq "" "$OUT"
  assert_eq true "$(overrides '[.target[].output == ["type=cacheonly"]] | all')"
  assert_eq false "$(overrides '[.target[] | has("cache-to")] | any')"
  assert_contains "$(calls)" "--progress=plain app app-test"
}

test_a_pull_request_imports_the_release_cache_by_digest() {
  setup
  registry_has "$CACHE:current" "$K1"
  build pr
  assert_status 0
  assert_eq "[\"type=registry,ref=$CACHE@$K1\"]" "$(overrides '.target.app."cache-from"')"
  assert_eq "[\"type=registry,ref=$CACHE@$K1\"]" "$(overrides '.target["app-test"]."cache-from"')"
}

test_a_run_that_cannot_read_the_cache_imports_none() {
  setup
  registry_has "$CACHE:current" "$K1"
  build pr false
  assert_status 0
  assert_eq '[]' "$(overrides '.target.app."cache-from"')"
  assert_not_contains "$(calls)" "imagetools inspect"
}

test_an_image_with_no_release_cache_yet_starts_cold() {
  setup
  build pr
  assert_status 0
  assert_eq '[]' "$(overrides '.target.app."cache-from"')"
  assert_contains "$ERR" "this build starts cold"
}

test_a_cache_lookup_error_stops_before_building() {
  setup
  registry_fails "$CACHE:current" "ERROR: unexpected status from HEAD request to https://r.example/v2/k/manifests/current: 403 Forbidden"
  build pr
  assert_status 1
  assert_contains "$ERR" "could not read the release cache $CACHE:current"
  assert_not_contains "$(calls)" "docker buildx bake"
}

test_a_pull_requests_test_stage_reruns_rather_than_matching_a_cache() {
  setup
  build pr
  assert_status 0
  assert_eq '["test"]' "$(overrides '.target["app-test"]."no-cache-filter"')"
  assert_eq true "$(overrides '[.target[].call == "build"] | all')"
}

test_a_push_pushes_each_image_by_digest_and_its_cache_under_the_runs_tag() {
  setup
  registry_has "$CACHE:current" "$K1"
  pushed
  build push
  assert_status 0
  assert_eq "{\"fresh\":false,\"targets\":{\"app\":{\"digest\":\"$D1\",\"cache_digest\":\"$C1\"}}}" "$(jq -c . <<<"$OUT")"
  assert_eq "[\"type=image,name=$CAND,push-by-digest=true,name-canonical=true,push=true\"]" "$(overrides '.target.app.output')"
  assert_eq "[\"type=registry,ref=$CAND:cache-4242-2,mode=max,oci-mediatypes=true,image-manifest=true\"]" "$(overrides '.target.app."cache-to"')"
  assert_eq "[\"type=registry,ref=$CACHE@$K1\"]" "$(overrides '.target.app."cache-from"')"
}

test_a_push_that_imports_no_cache_builds_from_scratch_and_says_so() {
  setup
  registry_has "$CACHE:current" "$K1"
  pushed
  build push false
  assert_status 0
  assert_eq true "$(jq -r .fresh <<<"$OUT")"
  assert_eq '[]' "$(overrides '.target.app."cache-from"')"
  assert_not_contains "$(calls)" "$CACHE:current"
}

test_a_push_builds_the_images_but_not_their_tests() {
  setup
  pushed
  build push
  assert_status 0
  assert_eq false "$(overrides '.target | has("app-test")')"
  assert_contains "$(calls)" "--progress=plain app"
  assert_not_contains "$(calls)" "app-test"
}

test_a_push_with_no_image_digest_fails() {
  setup
  pushed
  echo '{"app": {}}' >"$FAKE_STATE/metadata.json"
  build push
  assert_status 1
  assert_contains "$ERR" "app: the build reported no image digest"
}

test_a_push_with_no_cache_manifest_fails() {
  setup
  jq -n --arg d "$D1" '{app: {"containerimage.digest": $d}}' >"$FAKE_STATE/metadata.json"
  build push
  assert_status 1
  assert_contains "$ERR" "app: the build reported no cache manifest"
}

test_a_single_platform_push_must_be_one_manifest() {
  setup
  pushed
  echo '{"mediaType": "application/vnd.oci.image.index.v1+json", "manifests": []}' >"$FAKE_STATE/manifest"
  build push
  assert_status 1
  assert_contains "$ERR" "a single-platform build must push one image manifest"
}

test_bake_runs_without_the_jobs_credentials() {
  setup
  export AWS_SECRET_ACCESS_KEY=secret
  build pr
  assert_status 0
  assert_contains "$(calls)" "bake-env aws=[] builder=[] lookup=[1]"
}

test_a_failed_bake_fails_the_build() {
  setup
  echo 1 >"$FAKE_STATE/bake-status"
  build pr
  assert_status 1
  assert_contains "$ERR" "the build of app app-test failed"
}

test_refuses_a_month_where_the_import_flag_goes() {
  setup
  run "$PIPELINE_DIR/build.sh" "$W/targets.json" "$W/resolved.json" pr 2026-10 4242 2 "$W"
  assert_status 1
  assert_contains "$ERR" "import must be true or false, got 2026-10"
}

test_refuses_a_run_attempt_that_is_not_a_number() {
  setup
  run "$PIPELINE_DIR/build.sh" "$W/targets.json" "$W/resolved.json" push true 4242 2x "$W"
  assert_status 1
  assert_contains "$ERR" "the run attempt must be a number"
}

run_tests
