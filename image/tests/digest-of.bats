load helper

D1=sha256:$(printf '%064x' 1)

setup() { fresh_state; }

@test "prints the digest of a reference that exists" {
  registry_has r.example/app:t "$D1"
  run --separate-stderr "$SCRIPTS/digest-of.sh" r.example/app:t
  assert_success
  assert_output "$D1"
  assert_equal "$(calls)" "docker buildx imagetools inspect --format {{json .Manifest}} r.example/app:t"
}

@test "prints nothing for a reference that does not exist" {
  registry_fails r.example/app:missing "ERROR: r.example/app:missing: not found"
  run --separate-stderr "$SCRIPTS/digest-of.sh" r.example/app:missing
  assert_success
  assert_output ""
}

@test "fails on a denied lookup, with buildx's error" {
  registry_fails r.example/app:t "ERROR: unexpected status from HEAD request to https://r.example/v2/app/manifests/t: 403 Forbidden"
  run --separate-stderr "$SCRIPTS/digest-of.sh" r.example/app:t
  assert_failure
  assert_output ""
  assert_equal "$stderr" "ERROR: unexpected status from HEAD request to https://r.example/v2/app/manifests/t: 403 Forbidden
::error::Could not read r.example/app:t."
}

@test "fails when buildx's error says not found about something other than the reference" {
  registry_fails r.example/app:t "ERROR: failed to authorize: token endpoint not found"
  run --separate-stderr "$SCRIPTS/digest-of.sh" r.example/app:t
  assert_failure
  assert_output ""
}

@test "fails on an answer that names no digest" {
  registry_has r.example/app:t not-a-digest
  run --separate-stderr "$SCRIPTS/digest-of.sh" r.example/app:t
  assert_failure
  assert_output ""
  [[ $stderr == *"::error::Could not read r.example/app:t."* ]]
}
