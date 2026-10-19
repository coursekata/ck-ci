#!/usr/bin/env bash
# Runs one target's tests on exactly the bytes under test. The Dockerfile stage the
# tests build on is replaced by the image at its digest, nothing is imported from or
# exported to a cache, and no-cache re-runs every test step. The build is forced to
# be a build, not a check, and fails unless BuildKit resolved the image: a test stage
# that does not build on the replaced stage would otherwise pass on a rebuild from
# source. Run in a job whose builder has run no earlier test build of this target:
# the build job runs each test once, after its image is pushed.
# usage: test.sh <resolved.json> <test target> <replaced stage> <repository@digest> <work dir>
# Run from the repository root.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$here/lib.sh"

resolved=$1 test=$2 replaces=$3 image=$4 work=$5
[[ $image =~ @sha256:[0-9a-f]{64}$ ]] || die "the image under test must be named by digest, got $image"
mkdir -p "$work"

jq -n --arg t "$test" --arg s "$replaces" --arg i "docker-image://$image" \
  '{target: {($t): {contexts: {($s): $i}, "no-cache": true, call: "build", output: ["type=cacheonly"]}}}' \
  >"$work/test-overrides.json"

log="$work/test-$test.log"
if ! bake_clean -f "$resolved" -f "$work/test-overrides.json" --progress=plain "$test" 2>&1 | tee "$log" >&2; then
  die "$test failed on $image"
fi
grep -qF "[context $replaces] $image" "$log" ||
  die "$test never built on the image under test: no stage it built resolved the named context $replaces, so its tests ran on something else"
