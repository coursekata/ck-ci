# preflight.jq's decisions, on bake definitions written as `bake --print` prints them.
# shellcheck disable=SC2016 # the backticks are the messages' own, and $i and $t are jq's
load helper

# check <image target json> <test target json>: the preflight's answer for the targets app and
# app-test, compact.
check() {
  jq -n -c -L "$SCRIPTS" --argjson i "$1" --argjson t "$2" \
    'include "preflight"; {target: {app: $i, "app-test": $t}} | check("app"; "app-test")'
}

@test "outputs the image's stage and its platforms, sorted" {
  run check '{"target": "runtime", "platforms": ["linux/arm64", "linux/amd64"]}' '{"target": "test", "platforms": ["linux/amd64", "linux/arm64"]}'
  assert_output '{"stage":"runtime","platforms":["linux/amd64","linux/arm64"]}'
}

@test "an image target that names no stage fails" {
  run check '{}' '{"target": "test"}'
  assert_output --partial '"error":"The app'"'"'s bake target `app` names no stage to build to.'
}

@test "a test target that names no stage fails" {
  run check '{"target": "runtime"}' '{}'
  assert_output --partial '"error":"The test bake target `app-test` names no stage to build to.'
}

@test "a test target that builds the image's own stage fails" {
  run check '{"target": "runtime"}' '{"target": "runtime"}'
  assert_output --partial '"error":"The test bake target `app-test` builds to the same stage as the app'"'"'s bake target `app`.'
}

@test "a platform the image ships but its tests do not build fails" {
  run check '{"target": "runtime", "platforms": ["linux/amd64", "linux/arm64"]}' '{"target": "test", "platforms": ["linux/amd64"]}'
  assert_output --partial 'ships [\"linux/amd64\",\"linux/arm64\"], but the test bake target `app-test` builds for [\"linux/amd64\"].'
}

@test "an image target that sets its own cache fails" {
  run check '{"target": "runtime", "cache-from": ["type=gha"]}' '{"target": "test"}'
  assert_output '{"error":"The bake target `app` sets cache-from. build-action sets every cache and output itself, so a build reads only the release cache and nothing leaves the runner before push-action: remove cache-from, cache-to and output from the bake file'"'"'s image and test targets."}'
}

@test "a test target that writes its own cache fails" {
  run check '{"target": "runtime"}' '{"target": "test", "cache-to": ["type=inline"]}'
  assert_output --partial '"error":"The bake target `app-test` sets cache-to.'
}

@test "a test target that sets its own output fails" {
  run check '{"target": "runtime"}' '{"target": "test", "output": ["type=registry"]}'
  assert_output --partial '"error":"The bake target `app-test` sets output.'
}

@test "a platform written with its default variant is the same platform" {
  run check '{"target": "runtime", "platforms": ["linux/arm64/v8", "linux/amd64/v1"]}' '{"target": "test", "platforms": ["linux/amd64", "linux/arm64"]}'
  assert_output '{"stage":"runtime","platforms":["linux/amd64","linux/arm64"]}'
}
