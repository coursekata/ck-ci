#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

A=123456789012.dkr.ecr.us-west-2.amazonaws.com
B=210987654321.dkr.ecr.us-east-1.amazonaws.com

targets() {
  W=$(mktemp -d)
  jq -nc --arg c "$1/c" --arg r "$2/r" --arg k "$1/k" \
    '[{target: "app", test: "app-test", replaces: "runtime", candidate: $c, release: $r, cache: $k}]' >"$W/targets.json"
}

test_logs_in_to_each_ecr_registry_once_in_its_region() {
  fresh_state
  targets "$A" "$B"
  run "$PIPELINE_DIR/registry-login.sh" "$W/targets.json"
  assert_status 0
  assert_eq 1 "$(calls | grep -c "docker login --username AWS --password-stdin $A <fake-password>")"
  assert_eq 1 "$(calls | grep -c "docker login --username AWS --password-stdin $B <fake-password>")"
  assert_contains "$(calls)" "aws ecr get-login-password --region us-west-2"
  assert_contains "$(calls)" "aws ecr get-login-password --region us-east-1"
}

test_refuses_a_registry_that_is_not_ecr() {
  fresh_state
  targets "$A" ghcr.io/coursekata
  run "$PIPELINE_DIR/registry-login.sh" "$W/targets.json"
  assert_status 1
  assert_contains "$ERR" "ghcr.io is not an ECR registry"
}

run_tests
