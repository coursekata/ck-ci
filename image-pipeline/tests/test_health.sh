#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CAND=r.example/c
D1=sha256:$(printf '%064x' 1)
COMPOSE="$PIPELINE_DIR/health.compose.yml"

setup() {
  fresh_state
  W=$(mktemp -d)
  jq -nc --arg c "$CAND" '[{target: "app", test: "app-test", replaces: "runtime",
    candidate: $c, release: "r.example/r", cache: "r.example/k"}]' >"$W/targets.json"
  jq -n '{target: {app: {target: "runtime", platforms: ["linux/arm64"]},
    "app-test": {target: "test", platforms: ["linux/arm64"]}}}' >"$W/resolved.json"
  jq -n --arg d "$D1" '{fresh: false, targets: {app: {digest: $d, cache_digest: $d}}}' >"$W/build.json"
  echo linux/arm64 >"$FAKE_STATE/platform"
  echo '["CMD-SHELL","wget -q -O /dev/null http://127.0.0.1:8080/"]' >"$FAKE_STATE/healthcheck"
}

health_pr() { run "$PIPELINE_DIR/health.sh" "$W/targets.json" "$W/resolved.json" pr "$W"; }
health_push() { run "$PIPELINE_DIR/health.sh" "$W/targets.json" "$W/resolved.json" push "$W" "$W/build.json"; }

# edit <file> <jq program>: rewrites a JSON file in place.
edit() { jq "$2" "$1" >"$1.new" && mv "$1.new" "$1"; }

test_a_push_runs_the_tested_digest_on_the_runners_platform() {
  setup
  health_push
  assert_status 0
  assert_eq "" "$OUT"
  assert_contains "$(calls)" "docker pull --quiet --platform linux/arm64 $CAND@$D1"
  assert_contains "$(calls)" "docker compose -p image-pipeline-health-1 -f $COMPOSE up --wait --wait-timeout 600 candidate"
  assert_contains "$(calls)" "compose-env image=[$CAND@$D1]"
  assert_contains "$(calls)" "docker compose -p image-pipeline-health-1 -f $COMPOSE down"
}

test_a_pull_request_loads_its_own_build_for_the_runners_platform() {
  setup
  health_pr
  assert_status 0
  assert_eq '["linux/arm64"]' "$(jq -c '.target.app.platforms' "$W/health-overrides.json")"
  assert_eq '["type=docker,name=image-pipeline-health:pr-1"]' "$(jq -c '.target.app.output' "$W/health-overrides.json")"
  assert_contains "$(calls)" "compose-env image=[image-pipeline-health:pr-1]"
  assert_not_contains "$(calls)" "docker pull"
}

test_an_image_that_declares_no_healthcheck_warns_and_runs_nothing() {
  setup
  rm "$FAKE_STATE/healthcheck"
  health_push
  assert_status 0
  assert_contains "$OUT" "::warning::app declares no HEALTHCHECK"
  assert_not_contains "$(calls)" "docker compose"
}

test_healthcheck_none_warns_like_no_healthcheck() {
  setup
  echo '["NONE"]' >"$FAKE_STATE/healthcheck"
  health_push
  assert_status 0
  assert_contains "$OUT" "::warning::app declares no HEALTHCHECK"
  assert_not_contains "$(calls)" "docker compose"
}

test_an_image_that_does_not_ship_the_runners_platform_warns_and_runs_nothing() {
  setup
  echo linux/amd64 >"$FAKE_STATE/platform"
  health_push
  assert_status 0
  assert_contains "$OUT" "::warning::app ships [\"linux/arm64\"], not this runner's linux/amd64"
  assert_not_contains "$(calls)" "docker pull"
  assert_not_contains "$(calls)" "docker compose"
}

test_an_image_that_names_no_platforms_runs_on_the_runner() {
  setup
  edit "$W/resolved.json" 'del(.target.app.platforms)'
  echo linux/amd64 >"$FAKE_STATE/platform"
  health_push
  assert_status 0
  assert_contains "$(calls)" "docker pull --quiet --platform linux/amd64 $CAND@$D1"
}

test_a_target_set_to_skip_runs_nothing_and_warns_nothing() {
  setup
  edit "$W/targets.json" '.[0].healthcheck = false'
  health_push
  assert_status 0
  assert_eq "" "$OUT"
  assert_not_contains "$(calls)" "docker pull"
  assert_not_contains "$(calls)" "docker compose"
}

test_an_unhealthy_image_fails_with_its_logs_and_is_removed() {
  setup
  echo 1 >"$FAKE_STATE/compose-status"
  health_push
  assert_status 1
  assert_contains "$ERR" "the service's last words"
  assert_contains "$ERR" "app did not become healthy"
  assert_contains "$(calls)" "docker compose -p image-pipeline-health-1 -f $COMPOSE down"
}

test_the_compose_file_runs_the_image_alone_with_no_mounts_and_no_network() {
  assert_eq candidate "$(yq -r '.services | keys | join(",")' "$COMPOSE")"
  assert_eq image,network_mode,pull_policy "$(yq -r '.services.candidate | keys | sort | join(",")' "$COMPOSE")"
  assert_eq none "$(yq -r '.services.candidate.network_mode' "$COMPOSE")"
  assert_eq never "$(yq -r '.services.candidate.pull_policy' "$COMPOSE")"
  assert_eq '${IMAGE_REF:?IMAGE_REF is required}' "$(yq -r '.services.candidate.image' "$COMPOSE")"
}

run_tests
