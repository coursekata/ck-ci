load helper

cfg() { # cfg <revision> [<extra jq>]: a single-platform config, as buildx parses it.
  jq -nc --arg r "$1" '{architecture: "arm64", os: "linux", created: "2026-10-20T01:00:00Z",
    config: {Cmd: ["run"], Labels: {"org.opencontainers.image.revision": $r, "org.opencontainers.image.created": ("t-" + $r),
      "org.opencontainers.image.version": ("sha-" + $r), "org.opencontainers.image.title": "app"}},
    rootfs: {type: "layers", diff_ids: ["sha256:aa"]}, history: [{created_by: "RUN build"}]}' | jq -c "${2:-.}"
}

setup() {
  fresh_state
  export CANDIDATE_REF=r.example/candidate@sha256:c BASELINE_REF=r.example/release@sha256:b
}

@test "an image that differs only in the labels each run sets is unchanged" {
  image_config "$CANDIDATE_REF" "$(cfg new)"
  image_config "$BASELINE_REF" "$(cfg old)"
  run "$SCRIPTS/compare-release.sh"
  assert_success
  assert_equal "$(step_output unchanged)" true
}

@test "outputs the baseline's commit from its revision label" {
  image_config "$CANDIDATE_REF" "$(cfg new)"
  image_config "$BASELINE_REF" "$(cfg old)"
  run "$SCRIPTS/compare-release.sh"
  assert_equal "$(step_output revision)" old
}

@test "outputs an empty commit for a baseline with no revision label" {
  image_config "$CANDIDATE_REF" "$(cfg new)"
  image_config "$BASELINE_REF" "$(cfg old 'del(.config.Labels["org.opencontainers.image.revision"])')"
  run "$SCRIPTS/compare-release.sh"
  assert_equal "$(step_output revision)" ""
}

@test "a different layer is a change" {
  image_config "$CANDIDATE_REF" "$(cfg new '.rootfs.diff_ids = ["sha256:bb"]')"
  image_config "$BASELINE_REF" "$(cfg old)"
  run "$SCRIPTS/compare-release.sh"
  assert_success
  refute_output --partial "::warning::"
  assert_equal "$(step_output unchanged)" false
}

@test "a HEALTHCHECK change, seen only in the history, is a change" {
  image_config "$CANDIDATE_REF" "$(cfg new '.history += [{created_by: "HEALTHCHECK {Test:[CMD true]}", empty_layer: true}]')"
  image_config "$BASELINE_REF" "$(cfg old)"
  run "$SCRIPTS/compare-release.sh"
  assert_success
  refute_output --partial "::warning::"
  assert_equal "$(step_output unchanged)" false
}

@test "a label the Dockerfile writes is a change" {
  image_config "$CANDIDATE_REF" "$(cfg new '.config.Labels["org.opencontainers.image.title"] = "renamed"')"
  image_config "$BASELINE_REF" "$(cfg old)"
  run "$SCRIPTS/compare-release.sh"
  assert_success
  refute_output --partial "::warning::"
  assert_equal "$(step_output unchanged)" false
}

@test "a different set of platforms is a change" {
  image_config "$CANDIDATE_REF" "$(jq -nc --argjson a "$(cfg new)" '{"linux/arm64": $a, "linux/amd64": ($a | .architecture = "amd64")}')"
  image_config "$BASELINE_REF" "$(cfg old)"
  run "$SCRIPTS/compare-release.sh"
  assert_success
  refute_output --partial "::warning::"
  assert_equal "$(step_output unchanged)" false
}

@test "a multi-platform image matches platform by platform" {
  image_config "$CANDIDATE_REF" "$(jq -nc --argjson a "$(cfg new)" '{"linux/arm64": $a, "linux/amd64": ($a | .architecture = "amd64")}')"
  image_config "$BASELINE_REF" "$(jq -nc --argjson a "$(cfg old)" '{"linux/arm64": $a, "linux/amd64": ($a | .architecture = "amd64")}')"
  run "$SCRIPTS/compare-release.sh"
  assert_equal "$(step_output unchanged)" true
}

@test "a config it cannot read is a change, with a warning" {
  image_config "$CANDIDATE_REF" "$(cfg new)"
  run "$SCRIPTS/compare-release.sh"
  assert_success
  assert_equal "$(step_output unchanged)" false
  assert_output --partial "::warning::Could not read the configs of $CANDIDATE_REF and $BASELINE_REF, so the image releases as new."
}

@test "a different history timestamp alone is unchanged" {
  image_config "$CANDIDATE_REF" "$(cfg new '.history[0].created = "2026-10-20T02:00:00Z"')"
  image_config "$BASELINE_REF" "$(cfg old '.history[0].created = "2026-10-20T01:00:00Z"')"
  run "$SCRIPTS/compare-release.sh"
  assert_success
  assert_equal "$(step_output unchanged)" true
}

@test "a different image creation time alone is unchanged" {
  image_config "$CANDIDATE_REF" "$(cfg new '.created = "2026-10-20T02:00:00Z"')"
  image_config "$BASELINE_REF" "$(cfg old)"
  run "$SCRIPTS/compare-release.sh"
  assert_success
  assert_equal "$(step_output unchanged)" true
}

@test "a different history instruction is a change" {
  image_config "$CANDIDATE_REF" "$(cfg new '.history[0].created_by = "RUN other"')"
  image_config "$BASELINE_REF" "$(cfg old)"
  run "$SCRIPTS/compare-release.sh"
  assert_success
  refute_output --partial "::warning::"
  assert_equal "$(step_output unchanged)" false
}
