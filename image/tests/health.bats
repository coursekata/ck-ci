# health.jq's decisions, on `docker image inspect` output, and health.sh's refusal of no image.
# shellcheck disable=SC2016 # the filters are jq, and $i and $p are jq's
load helper

# inspect [<healthcheck test json>] [<os/architecture>]: inspect's JSON for an image built for that
# platform (linux/arm64 by default), declaring that health check, or none.
inspect() {
  jq -n -c --arg p "${2:-linux/arm64}" --argjson t "${1:-null}" \
    '[{Os: ($p | split("/")[0]), Architecture: ($p | split("/")[1]), Config: (if $t then {Healthcheck: {Test: $t}} else {} end)}]'
}
check() { jq -c -L "$SCRIPTS" --arg i r.example/c --arg p linux/arm64 'include "health"; check($i; $p)'; }

@test "an image with a health check, built for the runner's platform, runs" {
  run check <<<"$(inspect '["CMD-SHELL", "wget -q -O /dev/null http://127.0.0.1:8080/"]')"
  assert_output '{}'
}

@test "an image that declares no health check warns and does not run" {
  run check <<<"$(inspect)"
  assert_output '{"warning":"r.example/c declares no HEALTHCHECK, so no health check ran for it."}'
}

@test "HEALTHCHECK NONE warns like no health check" {
  run check <<<"$(inspect '["NONE"]')"
  assert_output --partial 'declares no HEALTHCHECK'
}

@test "an image built for another platform warns and does not run" {
  run check <<<"$(inspect '["CMD", "true"]' linux/amd64)"
  assert_output '{"warning":"r.example/c is built for linux/amd64, not this runner'"'"'s linux/arm64, so no health check ran for it."}'
}

@test "no image fails, naming the guard to use" {
  run "$SCRIPTS/health.sh" ""
  assert_failure
  assert_output "::error::No image was given to check. build-action loads none when the image does not ship this runner's platform; guard the step with if: when that is expected."
}
