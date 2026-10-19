#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

setup() {
  fresh_state
  W=$(mktemp -d)
  : >"$W/docker-bake.hcl"
  jq -nc '[{target: "app", test: "app-test", replaces: "runtime",
    candidate: "r.example/c", release: "r.example/r", cache: "r.example/k"}]' >"$W/targets.json"
  printed '.'
}

# printed <jq edit>: what the fake bake prints for --print, edited from a definition
# that passes every check.
printed() {
  jq -n '{target: {
    app: {context: "app", dockerfile: "Dockerfile", target: "runtime",
      tags: ["r.example/app:dev"], output: ["type=docker"],
      attest: [{type: "provenance", disabled: true}, {type: "sbom", disabled: true}]},
    "app-test": {context: "app", dockerfile: "Dockerfile", target: "test"}}}' |
    jq "$1" >"$FAKE_STATE/bake-print"
}

resolve() { run "$PIPELINE_DIR/resolve.sh" "$W/docker-bake.hcl" "$W/targets.json"; }

test_prints_the_definition_without_the_fields_each_run_sets() {
  setup
  resolve
  assert_status 0
  assert_eq runtime "$(jq -r '.target.app.target' <<<"$OUT")"
  assert_eq false "$(jq '[.target[] | has("tags") or has("output") or has("cache-from") or has("cache-to")] | any' <<<"$OUT")"
}

test_resolves_with_attestations_off_and_none_of_the_jobs_environment() {
  setup
  export AWS_SECRET_ACCESS_KEY=secret
  resolve
  assert_status 0
  assert_contains "$(calls)" "--provenance=false --sbom=false --print app app-test"
  assert_contains "$(calls)" "bake-env aws=[] builder=[] lookup=[1]"
}

test_refuses_an_image_that_does_not_build_the_stage_its_test_replaces() {
  setup
  printed '.target.app.target = "builder"'
  resolve
  assert_status 1
  assert_contains "$ERR" "app builds stage 'builder', but its test app-test replaces stage 'runtime'"
}

test_refuses_a_test_that_builds_the_replaced_stage_itself() {
  setup
  printed '.target["app-test"].target = "runtime"'
  resolve
  assert_status 1
  assert_contains "$ERR" "app-test must build a stage of its own on top of runtime"
}

test_refuses_a_test_with_no_stage() {
  setup
  printed 'del(.target["app-test"].target)'
  resolve
  assert_status 1
  assert_contains "$ERR" "app-test must build a stage of its own"
}

test_refuses_a_test_that_leaves_a_shipped_platform_untested() {
  setup
  printed '.target.app.platforms = ["linux/amd64", "linux/arm64"] | .target["app-test"].platforms = ["linux/amd64"]'
  resolve
  assert_status 1
  assert_contains "$ERR" "Every platform an image ships must be tested"
}

test_accepts_the_same_platforms_in_another_order() {
  setup
  printed '.target.app.platforms = ["linux/arm64", "linux/amd64"] | .target["app-test"].platforms = ["linux/amd64", "linux/arm64"]'
  resolve
  assert_status 0
}

test_refuses_a_bake_file_that_lacks_a_configured_target() {
  setup
  printed 'del(.target["app-test"])'
  resolve
  assert_status 1
  assert_contains "$ERR" "does not define every configured target"
}

test_stops_when_bake_cannot_resolve() {
  setup
  echo 1 >"$FAKE_STATE/bake-status"
  resolve
  assert_status 1
  assert_contains "$ERR" "bake could not resolve app app-test"
}

run_tests
