#!/usr/bin/env bash
# Runs each image's own HEALTHCHECK under compose, on this runner's platform, and
# fails when an image does not become healthy. The compose file beside this script
# runs the image as its only service, with no mounts and no network. Docker decides
# what healthy means, from the image's own interval, timeout, retries and start
# period; the ten-minute wait is only a backstop.
#
# pr: the image is loaded into Docker from this job's build, which the builder's
# cache makes an export rather than a rebuild. push: the tested candidate is pulled
# by digest.
#
# Two checks come first, because Docker and compose would get both cases wrong
# without complaint. Docker pulls a single-platform digest whatever platform is asked
# for, and bake builds any platform it is told to, so an image that does not ship
# this runner's platform gets a warning and no run. Compose calls a service with no
# health check healthy as soon as it starts, so an image that declares none gets a
# warning and no run too. A target set to "healthcheck": false is skipped silently.
# usage: health.sh <targets.json> <resolved.json> pr <work dir>
#        health.sh <targets.json> <resolved.json> push <work dir> <build.json>
# Warnings go to stdout as workflow commands, everything else to stderr.
# Run from the repository root.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$here/lib.sh"

targets=$1 resolved=$2 mode=$3 work=$4 build=${5:-}
compose_file="$here/health.compose.yml"
platform=$(docker version --format '{{.Server.Os}}/{{.Server.Arch}}')

# compose <project> <image> <compose args...>: compose on the shipped file, for one image.
compose() { IMAGE_REF=$2 docker compose -p "$1" -f "$compose_file" "${@:3}"; }

n=0
# jq's // treats false as missing, so has() decides whether a target set the key.
while IFS=$'\t' read -r t candidate healthcheck; do
  n=$((n + 1))
  [ "$healthcheck" != false ] || continue
  shipped=$(jq -c --arg t "$t" '.target[$t].platforms // []' "$resolved")
  if ! jq -e --arg p "$platform" 'length == 0 or any(.[]; . == $p)' <<<"$shipped" >/dev/null; then
    echo "::warning::$t ships $shipped, not this runner's $platform, so no health check ran for it."
    continue
  fi
  if [ "$mode" = push ]; then
    image="$candidate@$(jq -r --arg t "$t" '.targets[$t].digest' "$build")"
    docker pull --quiet --platform "$platform" "$image" >&2
  else
    image="image-pipeline-health:pr-$n"
    jq -n --arg t "$t" --arg p "$platform" --arg i "$image" \
      '{target: {($t): {call: "build", platforms: [$p], output: ["type=docker,name=\($i)"]}}}' >"$work/health-overrides.json"
    bake_clean -f "$resolved" -f "$work/health-overrides.json" --progress=plain "$t" >&2
  fi
  check=$(docker image inspect --format '{{if .Config.Healthcheck}}{{json .Config.Healthcheck.Test}}{{end}}' "$image")
  if [ -z "$check" ] || [ "$check" = '["NONE"]' ]; then
    echo "::warning::$t declares no HEALTHCHECK, so no health check is available for it. Set \"healthcheck\": false on the target to skip this run without the warning."
    continue
  fi
  project="image-pipeline-health-$n"
  if ! compose "$project" "$image" up --wait --wait-timeout 600 candidate >&2; then
    compose "$project" "$image" logs --no-color candidate >&2 || true
    compose "$project" "$image" down >&2 || true
    die "$t did not become healthy"
  fi
  compose "$project" "$image" down >&2
done < <(jq -r '.[] | [.target, .candidate, (if has("healthcheck") then .healthcheck else true end | tostring)] | @tsv' "$targets")
