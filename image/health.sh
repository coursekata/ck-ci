#!/usr/bin/env bash
# Runs an image's own HEALTHCHECK under compose, as the only service, with no mounts and no network,
# and fails if it does not become healthy. The image must already be in Docker. An image built for
# another platform, or that declares no health check, warns and runs nothing: Docker would run the
# wrong platform's image, and compose calls a service with no health check healthy the moment it
# starts.
# usage: health.sh <image>
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

image=${1:-}
if [ -z "$image" ]; then
  echo "::error::No image was given to check. build-action loads none when the image does not ship this runner's platform; guard the step with if: when that is expected."
  exit 1
fi
platform=$(docker version --format '{{.Server.Os}}/{{.Server.Arch}}')

built=$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$image")
if [ "$built" != "$platform" ]; then
  echo "::warning::$image is built for $built, not this runner's $platform, so no health check ran for it."
  exit 0
fi

check=$(docker image inspect --format '{{if .Config.Healthcheck}}{{json .Config.Healthcheck.Test}}{{end}}' "$image")
if [ -z "$check" ] || [ "$check" = '["NONE"]' ]; then
  echo "::warning::$image declares no HEALTHCHECK, so no health check ran for it."
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
