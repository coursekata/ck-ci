#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ECR=123456789012.dkr.ecr.us-west-2.amazonaws.com
VALID=$(jq -nc --arg r "$ECR" '[{target: "app", test: "app-test", replaces: "runtime",
  candidate: "\($r)/app-image-candidate", release: "\($r)/app-image-release", cache: "\($r)/app-image-cache"}]')

targets() { run "$PIPELINE_DIR/targets.sh" "$1"; }
edited() { jq -c "$1" <<<"$VALID"; }
rejected() {
  targets "$1"
  assert_status 1
  assert_contains "$ERR" "targets must be a JSON array"
}

test_accepts_one_target() {
  targets "$VALID"
  assert_status 0
  assert_eq "$VALID" "$OUT"
}

test_accepts_two_targets() {
  targets "$(edited '. + [.[0] | .target = "worker" | .test = "worker-test"
    | .candidate += "-w" | .release += "-w" | .cache += "-w"]')"
  assert_status 0
}

test_accepts_a_local_registry_with_a_port() {
  targets "$(edited '.[0].candidate = "localhost:5000/candidate/app"')"
  assert_status 0
}

test_rejects_an_empty_list() { rejected '[]'; }
test_rejects_text_that_is_not_json() { rejected 'not json'; }
test_rejects_a_missing_field() { rejected "$(edited 'del(.[0].replaces)')"; }
test_rejects_an_unknown_field() { rejected "$(edited '.[0].tags = ["x"]')"; }
test_rejects_a_tagged_repository() { rejected "$(edited '.[0].release += ":latest"')"; }
test_rejects_a_digest_repository() { rejected "$(edited '.[0].release += "@sha256:\("0" * 64)"')"; }
test_rejects_one_repository_for_two_areas() { rejected "$(edited '.[0].release = .[0].candidate')"; }
test_rejects_a_test_named_like_an_image() { rejected "$(edited '.[0].test = "app"')"; }
test_rejects_duplicate_targets() { rejected "$(edited '. + .')"; }
test_rejects_a_target_name_with_a_slash() { rejected "$(edited '.[0].target = "a/b"')"; }

test_accepts_a_target_that_skips_its_health_run() {
  targets "$(edited '.[0].healthcheck = false')"
  assert_status 0
}

test_accepts_a_target_that_keeps_its_health_run() {
  targets "$(edited '.[0].healthcheck = true')"
  assert_status 0
}

test_rejects_a_healthcheck_that_is_not_true_or_false() { rejected "$(edited '.[0].healthcheck = "false"')"; }

test_rejects_one_release_repository_for_two_images() {
  rejected "$(edited '. + [.[0] | .target = "worker" | .test = "worker-test" | .candidate += "-w" | .cache += "-w"]')"
}

run_tests
