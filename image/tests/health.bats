load helper

IMG=r.example/c@sha256:$(printf '%064x' 1)

setup() {
  fresh_state
  COMPOSE="$SCRIPTS/health.compose.yml"
  echo linux/arm64 >"$FAKE_STATE/platform"
  echo '["CMD-SHELL","wget -q -O /dev/null http://127.0.0.1:8080/"]' >"$FAKE_STATE/healthcheck"
}

@test "a healthy image passes, running the image it was given, and its container is removed" {
  run --separate-stderr "$SCRIPTS/health.sh" "$IMG"
  assert_success
  assert_output ""
  run calls
  assert_line "docker compose -p image-health -f $COMPOSE up --wait --wait-timeout 600 candidate"
  assert_line "compose-env image=[$IMG]"
  assert_line "docker compose -p image-health -f $COMPOSE down --volumes"
}

@test "an image that declares no health check warns and runs nothing" {
  rm "$FAKE_STATE/healthcheck"
  run "$SCRIPTS/health.sh" "$IMG"
  assert_success
  assert_output --partial "::warning::$IMG declares no HEALTHCHECK, so no health check ran for it."
  run calls
  refute_line --partial "docker compose"
}

@test "HEALTHCHECK NONE warns like no health check" {
  echo '["NONE"]' >"$FAKE_STATE/healthcheck"
  run "$SCRIPTS/health.sh" "$IMG"
  assert_success
  assert_output --partial "::warning::$IMG declares no HEALTHCHECK"
  run calls
  refute_line --partial "docker compose"
}

@test "an image built for another platform warns and runs nothing" {
  echo linux/amd64 >"$FAKE_STATE/image-platform"
  run "$SCRIPTS/health.sh" "$IMG"
  assert_success
  assert_output --partial "::warning::$IMG is built for linux/amd64, not this runner's linux/arm64, so no health check ran for it."
  run calls
  refute_line --partial "docker compose"
}

@test "an unhealthy image fails with its logs and is removed" {
  echo 1 >"$FAKE_STATE/compose-status"
  run "$SCRIPTS/health.sh" "$IMG"
  assert_failure
  assert_output --partial "the service's last words"
  assert_output --partial "::error::$IMG did not become healthy"
  run calls
  assert_line "docker compose -p image-health -f $COMPOSE down --volumes"
}

@test "no image fails, naming the guard to use" {
  run "$SCRIPTS/health.sh" ""
  assert_failure
  assert_output "::error::No image was given to check. build-action loads none when the image does not ship this runner's platform; guard the step with if: when that is expected."
  assert_equal "$(calls)" ""
}
