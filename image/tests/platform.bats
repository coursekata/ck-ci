# platform.jq's decisions, on platform lists and OCI indexes as load-image.sh reads them.
# shellcheck disable=SC2016 # the filters are jq, and $p is jq's
load helper

platform() { jq -c -L "$SCRIPTS/build-action" --arg p "$1" "include \"platform\"; $2"; }

# index <platform json>...: an OCI index with one manifest per platform, whose digest is its
# platform's os/architecture[/variant].
index() {
  jq -n -c '{manifests: [$ARGS.positional[] | fromjson | {digest: ([.os, .architecture, .variant // empty] | join("/")), platform: .}]}' --args "$@"
}

@test "an image ships the runner's platform when it lists it, in any variant Docker leaves off" {
  run platform linux/arm64 'ships($p)' <<<'["linux/amd64", "linux/arm64/v8"]'
  assert_output true
}

@test "an image that lists no platforms ships the runner's" {
  run platform linux/arm64 'ships($p)' <<<'[]'
  assert_output true
}

@test "an image that lists other platforms does not ship the runner's" {
  run platform linux/arm64 'ships($p)' <<<'["linux/amd64"]'
  assert_output false
}

@test "an index's manifest for the runner's platform is found, and none for a platform it lacks" {
  idx=$(index '{"os": "linux", "architecture": "amd64"}' '{"os": "linux", "architecture": "arm64"}' '{"os": "unknown", "architecture": "unknown"}')
  run platform linux/arm64 'for_platform($p)' <<<"$idx"
  assert_output '"linux/arm64"'
  run platform linux/riscv64 'for_platform($p)' <<<"$idx"
  assert_output null
}

@test "an index entry written with its platform's default variant is the runner's platform" {
  run platform linux/arm64 'for_platform($p)' <<<"$(index '{"os": "linux", "architecture": "arm64", "variant": "v8"}')"
  assert_output '"linux/arm64/v8"'
}
