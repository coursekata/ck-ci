#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$PIPELINE_DIR/.." && pwd)
WF="$ROOT/.github/workflows/image.yml"
ALLOWED='^(actions/checkout|aws-actions/configure-aws-credentials|docker/setup-buildx-action)@[0-9a-f]{40}$'

# need: a test over the workflow fails, rather than passing vacuously, when the file is missing.
need() { [ -f "$WF" ] || fail "no ${WF##*/}"; }
job_ids() { yq -r '.jobs | keys | .[]' "$WF"; }
# step <job> <step id> <field path>: one field of one step.
step() { yq -r ".jobs.$1.steps[] | select(.id == \"$2\") | .$3" "$WF"; }

# gate <step id> <VAR=value...>: runs that build step's script with only the given
# environment, and prints what it wrote to GITHUB_OUTPUT.
gate() {
  local id=$1 out script
  shift
  out=$(mktemp)
  script=$(step build "$id" run)
  env -i PATH="$PATH" GITHUB_OUTPUT="$out" "$@" bash -ec "$script" >/dev/null 2>&1 || return 1
  cat "$out"
}

test_the_workflow_is_only_ever_called() {
  need
  assert_eq workflow_call "$(yq -r '.on | keys | join(",")' "$WF")"
}

test_the_old_pair_of_workflows_is_gone() {
  [ ! -e "$ROOT/.github/workflows/image-build.yml" ] || fail "image-build.yml is still here"
  [ ! -e "$ROOT/.github/workflows/image-release.yml" ] || fail "image-release.yml is still here"
}

test_every_action_is_allowlisted_and_pinned_by_sha() {
  local u
  need
  while read -r u; do
    [[ $u =~ $ALLOWED ]] || fail "image.yml uses $u"
  done < <(yq -r '.jobs[].steps[].uses | select(. != null)' "$WF")
}

test_no_job_can_touch_the_actions_cache() {
  local job
  need
  while read -r job; do
    assert_eq none "$(yq -r ".jobs.$job.\"cache-mode\"" "$WF")" "$job's cache-mode"
  done < <(job_ids)
  if grep -nE 'actions/cache|type=gha' "$WF"; then fail "image.yml names the Actions cache"; fi
}

test_buildx_comes_from_its_pinned_setup_without_the_binary_cache() {
  local job s
  need
  for job in build release; do
    s=".jobs.$job.steps[] | select(.uses == \"docker/setup-buildx-action@*\") | .with"
    assert_eq false "$(yq -r "$s.\"cache-binary\"" "$WF")" "$job"
    assert_eq '${{ steps.pins.outputs.buildx }}' "$(yq -r "$s.version" "$WF")" "$job"
  done
  s='.jobs.build.steps[] | select(.uses == "docker/setup-buildx-action@*") | .with'
  assert_eq docker-container "$(yq -r "$s.driver" "$WF")"
  assert_eq 'image=${{ steps.pins.outputs.buildkit }}' "$(yq -r "$s.\"driver-opts\"" "$WF")"
}

test_the_release_copies_with_buildx_and_starts_no_builder() {
  need
  assert_eq docker "$(yq -r '.jobs.release.steps[] | select(.uses == "docker/setup-buildx-action@*") | .with.driver' "$WF")"
  if grep -nE 'install-tools|crane' "$WF"; then fail "image.yml installs a tool of its own"; fi
}

test_jobs_run_on_hosted_labels_only() {
  local r
  need
  while read -r r; do
    [[ $r == '${{ inputs.runner }}' || $r =~ ^ubuntu- ]] || fail "a job runs on $r"
  done < <(yq -r '.jobs[]."runs-on"' "$WF")
  [[ $(yq -r '.on.workflow_call.inputs.runner.default' "$WF") =~ ^ubuntu- ]] || fail "the default runner"
}

test_every_job_first_requires_a_hosted_runner_and_its_own_commit() {
  local job first
  need
  while read -r job; do
    first=$(yq -r ".jobs.$job.steps[0].run" "$WF")
    assert_contains "$first" RUNNER_ENVIRONMENT "$job"
    assert_contains "$first" WORKFLOW_SHA "$job"
  done < <(job_ids)
}

test_scripts_are_checked_out_at_the_workflow_commit() {
  local job
  need
  while read -r job; do
    assert_eq 0 "$(yq "[.jobs.$job.steps[] | select(.with.repository == \"coursekata/ck-tf-modules\") | select(.with.ref != \"\${{ job.workflow_sha }}\")] | length" "$WF")" "$job"
    [ "$(yq "[.jobs.$job.steps[] | select(.with.repository == \"coursekata/ck-tf-modules\")] | length" "$WF")" -gt 0 ] ||
      fail "$job never checks out the scripts"
  done < <(job_ids)
}

test_no_checkout_keeps_credentials() {
  need
  assert_eq 0 "$(yq '[.jobs[].steps[] | select(.uses == "actions/checkout@*") | select(.with."persist-credentials" != false)] | length' "$WF")"
}

test_the_required_check_reads_image_build() {
  need
  assert_eq build "$(yq -r '.jobs | keys | .[] | select(. == "build")' "$WF")"
  assert_eq null "$(yq -r '.jobs.build.name' "$WF")" "a name would change the check from image / build"
}

test_only_the_release_job_declares_an_environment() {
  need
  assert_eq 1 "$(yq '[.jobs[] | select(has("environment"))] | length' "$WF")"
  assert_eq release "$(yq -r '.jobs.release.environment' "$WF")"
}

test_the_release_runs_only_on_a_push_or_a_run_by_hand_and_only_after_the_build() {
  need
  assert_eq "github.event_name == 'push' || github.event_name == 'workflow_dispatch'" "$(yq -r '.jobs.release.if' "$WF")"
  assert_eq build "$(yq -r '.jobs.release.needs' "$WF")"
}

test_the_release_takes_its_digests_from_this_runs_build() {
  need
  assert_eq '${{ needs.build.outputs.build }}' "$(step release release env.BUILD)"
  assert_eq '${{ steps.test.outputs.build }}' "$(yq -r '.jobs.build.outputs.build' "$WF")"
  assert_eq '${{ jobs.release.outputs.digests }}' "$(yq -r '.on.workflow_call.outputs.digests.value' "$WF")"
}

test_images_are_tested_on_their_digests_only_on_a_push() {
  need
  assert_eq "steps.mode.outputs.mode == 'push'" "$(step build test if)"
  assert_contains "$(step build test run)" 'test.sh'
}

test_each_job_assumes_its_own_role() {
  need
  assert_eq '${{ steps.role.outputs.arn }}' "$(yq -r '.jobs.build.steps[] | select(.uses == "aws-actions/configure-aws-credentials@*") | .with."role-to-assume"' "$WF")"
  assert_eq '${{ inputs.release-role-arn }}' "$(yq -r '.jobs.release.steps[] | select(.uses == "aws-actions/configure-aws-credentials@*") | .with."role-to-assume"' "$WF")"
}

test_a_run_by_hand_builds_without_the_cache() {
  need
  assert_eq "\${{ steps.role.outputs.arn != '' && steps.mode.outputs.fresh != 'true' }}" "$(step build build env.IMPORT)"
}

test_the_mode_gate_admits_a_pull_request_and_a_push_or_a_run_by_hand_on_the_default_branch() {
  local e
  need
  assert_eq '${{ github.event_name }}' "$(step build mode env.EVENT)"
  assert_eq '${{ github.event.repository.default_branch }}' "$(step build mode env.DEFAULT_BRANCH)"
  assert_eq $'mode=pr\nfresh=false' "$(gate mode EVENT=pull_request GITHUB_REF=refs/pull/7/merge DEFAULT_BRANCH=main)"
  assert_eq $'mode=push\nfresh=false' "$(gate mode EVENT=push GITHUB_REF=refs/heads/main DEFAULT_BRANCH=main)"
  assert_eq $'mode=push\nfresh=true' "$(gate mode EVENT=workflow_dispatch GITHUB_REF=refs/heads/main DEFAULT_BRANCH=main)"
  for e in "EVENT=push GITHUB_REF=refs/heads/feature" "EVENT=push GITHUB_REF=refs/tags/v1" \
    "EVENT=workflow_dispatch GITHUB_REF=refs/heads/feature" "EVENT=schedule GITHUB_REF=refs/heads/main" \
    "EVENT=pull_request_target GITHUB_REF=refs/heads/main"; do
    # shellcheck disable=SC2086 # each case is two assignments
    if gate mode $e DEFAULT_BRANCH=main >/dev/null; then fail "the gate admits $e"; fi
  done
}

test_the_role_gate_gives_a_pull_request_only_the_cache_read_role() {
  local roles=(CANDIDATE_ROLE=arn:candidate CACHE_READ_ROLE=arn:cache-read)
  need
  assert_eq '${{ inputs.candidate-role-arn }}' "$(step build role env.CANDIDATE_ROLE)"
  assert_eq '${{ inputs.cache-read-role-arn }}' "$(step build role env.CACHE_READ_ROLE)"
  assert_eq arn=arn:candidate "$(gate role MODE=push ACTIONS_ID_TOKEN_REQUEST_URL=https://token.invalid "${roles[@]}")"
  assert_eq arn=arn:cache-read "$(gate role MODE=pr ACTIONS_ID_TOKEN_REQUEST_URL=https://token.invalid "${roles[@]}")"
  assert_eq arn= "$(gate role MODE=pr "${roles[@]}")" "a run with no OIDC token assumes no role"
}

test_the_build_secret_is_optional() {
  need
  assert_eq false "$(yq -r '.on.workflow_call.secrets."build-secret".required' "$WF")"
  assert_eq "" "$(yq -r '.on.workflow_call.inputs."build-secret-env".default' "$WF")"
}

test_the_build_secret_reaches_only_the_steps_that_bake() {
  local id
  need
  assert_eq build,test,health "$(yq -r '[.jobs[].steps[] | select(.env.BUILD_SECRET != null) | .id] | join(",")' "$WF")"
  for id in build test health; do
    assert_eq '${{ secrets.build-secret }}' "$(step build "$id" env.BUILD_SECRET)" "$id"
    assert_eq '${{ inputs.build-secret-env }}' "$(step build "$id" env.BUILD_SECRET_ENV)" "$id"
  done
  assert_eq 3 "$(grep -c 'secrets\.' "$WF")" "image.yml reads a secret outside the steps that bake"
}

test_every_image_gets_its_health_run_after_its_tests() {
  need
  assert_contains "$(yq -r '[.jobs.build.steps[].id | select(. != null)] | join(",")' "$WF")" "build,test,health"
  assert_eq null "$(step build health if)" "the health run must run on a pull request and on a push"
  assert_contains "$(step build health run)" health.sh
}

run_tests
