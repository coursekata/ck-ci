load helper

A=sha256:$(printf '%064x' 1)
B=sha256:$(printf '%064x' 2)
C=sha256:$(printf '%064x' 3)
R=r.example/release

setup() {
  fresh_state
  export RELEASE=$R DIGEST=$A GITHUB_SHA=abc TAGS=$'sha-abc\nrun-7'
}

@test "a first release needs every tag" {
  run "$SCRIPTS/read-release.sh"
  assert_success
  assert_equal "$(step_output found)" false
  assert_equal "$(step_output earlier)" ""
  assert_equal "$(step_output digest)" "$A"
  assert_equal "$(step_output missing)" "$R:sha-abc"$'\n'"$R:run-7"
  assert_equal "$(step_output named)" "$R:sha-abc"$'\n'"$R:run-7"
}

@test "a release cut short needs only the tags it lacks" {
  registry_has "$R:sha-abc" "$A"
  run "$SCRIPTS/read-release.sh"
  assert_success
  assert_equal "$(step_output found)" true
  assert_equal "$(step_output missing)" "$R:run-7"
}

@test "a finished release needs nothing" {
  registry_has "$R:sha-abc" "$A"
  registry_has "$R:run-7" "$A"
  run "$SCRIPTS/read-release.sh"
  assert_success
  assert_equal "$(step_output earlier)" ""
  assert_equal "$(step_output missing)" ""
}

@test "a commit already released stands, whatever this build is" {
  registry_has "$R:sha-abc" "$B"
  registry_has "$R:run-7" "$B"
  run "$SCRIPTS/read-release.sh"
  assert_success
  assert_equal "$(step_output found)" false
  assert_equal "$(step_output earlier)" "$B"
  assert_equal "$(step_output digest)" "$B"
  assert_equal "$(step_output missing)" ""
  assert_output "::notice::$R:sha-abc already names $B, an earlier release of this commit, which stands. Nothing was tagged with $A."
}

@test "another tag that names another image fails" {
  export TAGS=$'sha-abc\nrun-7\nmain'
  registry_has "$R:main" "$B"
  run "$SCRIPTS/read-release.sh"
  assert_failure
  assert_output "::error::$R:main already names $B, not this image $A, and a release tag can't be moved. Every tag must be new to each release."
}

@test "blank lines in the tags are skipped" {
  export TAGS=$'sha-abc\n\nrun-7\n'
  run "$SCRIPTS/read-release.sh"
  assert_success
  assert_equal "$(step_output missing)" "$R:sha-abc"$'\n'"$R:run-7"
}

@test "tags without the commit's tag fail" {
  export TAGS=run-7
  run "$SCRIPTS/read-release.sh"
  assert_failure
  assert_output "::error::The tags must include sha-abc, which marks this commit as released."
}

@test "a denied lookup fails" {
  registry_fails "$R:run-7" "ERROR: 403 Forbidden"
  run "$SCRIPTS/read-release.sh"
  assert_failure
  assert_output --partial "::error::Could not read $R:run-7."
}

@test "when an earlier release stands, only the tags that name it are named" {
  export TAGS=$'sha-abc\nrun-7\nmain'
  registry_has "$R:sha-abc" "$B"
  registry_has "$R:main" "$C"
  run "$SCRIPTS/read-release.sh"
  assert_success
  assert_equal "$(step_output named)" "$R:sha-abc"
}
