#!/usr/bin/env bash
# Validates the targets input the image workflow takes, and prints it compacted.
# Each image names its bake target, the bake target of its tests, the Dockerfile
# stage the tests build on (replaced by the image under test), and three distinct
# repositories with no tag or digest. No repository is named twice, within an image
# or across images: two images sharing a release repository would write the same
# sha-<commit> tag, and the second would report the first's digest as its own. An
# image may set healthcheck to false to skip its health run.
# usage: targets.sh '<json>'
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$here/lib.sh"

shape='[{"target": "<bake target>", "test": "<bake test target>", "replaces": "<stage>", "candidate": "<registry>/<repo>", "release": "<registry>/<repo>", "cache": "<registry>/<repo>", "healthcheck": <optional true or false>}]'

jq -e '
  def ident: type == "string" and test("^[A-Za-z0-9_-]+$");
  def stage: type == "string" and test("^[A-Za-z0-9_.-]+$");
  def repo: type == "string" and test("^[a-z0-9.-]+(:[0-9]+)?(/[a-z0-9._-]+)+$");
  type == "array" and length > 0
  and all(.[];
    type == "object"
    and (keys - ["healthcheck"]) == ["cache", "candidate", "release", "replaces", "target", "test"]
    and ((has("healthcheck") | not) or (.healthcheck | type == "boolean"))
    and (.target | ident) and (.test | ident) and (.replaces | stage)
    and (.candidate | repo) and (.release | repo) and (.cache | repo))
  and ([.[] | .target, .test] | unique | length) == 2 * length
  and ([.[] | .candidate, .release, .cache] | unique | length) == 3 * length
' <<<"$1" >/dev/null 2>&1 ||
  die "targets must be a JSON array shaped like $shape, with every target and test name distinct and no repository named twice, within an image or across images"

jq -c . <<<"$1"
