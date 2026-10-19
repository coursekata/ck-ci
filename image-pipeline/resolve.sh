#!/usr/bin/env bash
# Resolves the configured bake targets to one JSON definition, which the build and
# the tests then run from. Bake runs with nothing from the job's environment, and
# attestations are off, so a single-platform push is one manifest. The fields the
# workflow sets per run (tags, output, cache-from, cache-to) are removed; everything
# else stays as bake printed it.
#
# Each image target must build the stage its test replaces, and its test must build
# a stage of its own for the same platforms. Otherwise a test could pass on a fresh
# build from source, or leave a platform the image ships untested.
# usage: resolve.sh <bake file> <targets.json> > resolved.json
# Run from the repository root: bake reads each context against the working
# directory, not the bake file.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$here/lib.sh"

bake_file=$1 targets=$2
[ -f "$bake_file" ] || die "no bake file at $bake_file"
mapfile -t names < <(jq -r '.[] | .target, .test' "$targets")

printed=$(bake_clean -f "$bake_file" --provenance=false --sbom=false --print "${names[@]}") ||
  die "bake could not resolve ${names[*]} from $bake_file"

jq -e '. as $r | $ARGS.positional | all(. as $n | $r.target[$n] != null)' --args "${names[@]}" <<<"$printed" >/dev/null ||
  die "$bake_file does not define every configured target: ${names[*]}"

resolved=$(jq -S '.target |= map_values(del(.tags, .output, ."cache-from", ."cache-to"))' <<<"$printed")

while IFS=$'\t' read -r t test replaces; do
  stage=$(jq -r --arg t "$t" '.target[$t].target // ""' <<<"$resolved")
  [ "$stage" = "$replaces" ] ||
    die "$t builds stage '$stage', but its test $test replaces stage '$replaces'. The test must build on the image under test, so the two must be the same stage."
  test_stage=$(jq -r --arg t "$test" '.target[$t].target // ""' <<<"$resolved")
  if [ -z "$test_stage" ] || [ "$test_stage" = "$replaces" ]; then
    die "$test must build a stage of its own on top of $replaces, but it builds '$test_stage'"
  fi
  shipped=$(jq -c --arg t "$t" '.target[$t].platforms // [] | sort' <<<"$resolved")
  tested=$(jq -c --arg t "$test" '.target[$t].platforms // [] | sort' <<<"$resolved")
  [ "$shipped" = "$tested" ] ||
    die "$t ships $shipped, but $test builds for $tested. Every platform an image ships must be tested."
done < <(jq -r '.[] | [.target, .test, .replaces] | @tsv' "$targets")

printf '%s\n' "$resolved"
