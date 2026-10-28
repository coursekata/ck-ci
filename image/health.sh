#!/usr/bin/env bash
# Runs an image's own HEALTHCHECK under compose, as the only service, with no mounts and no network,
# and fails if it does not become healthy. The image must already be in Docker. health.jq decides
# from the image's inspect whether it runs; one that does not warns and runs nothing.
# usage: health.sh <image>
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

image=${1:-}
if [ -z "$image" ]; then
  echo "::error::No image was given to check. build-action loads none when the image does not ship this runner's platform; guard the step with if: when that is expected."
  exit 1
fi
platform=$(docker version --format '{{.Server.Os}}/{{.Server.Arch}}')
decision=$(docker image inspect "$image" | jq -L "$here" -c --arg i "$image" --arg p "$platform" 'include "health"; check($i; $p)')
if warning=$(jq -er .warning <<<"$decision"); then
  echo "::warning::$warning"
  exit 0
fi

compose() { IMAGE_REF=$image docker compose -p image-health -f "$here/health.compose.yml" "$@"; }
if ! compose up --wait --wait-timeout 600 candidate >&2; then
  compose logs --no-color candidate >&2 || true
  compose down --volumes >&2 || true
  echo "::error::$image did not become healthy" >&2
  exit 1
fi
compose down --volumes >&2
