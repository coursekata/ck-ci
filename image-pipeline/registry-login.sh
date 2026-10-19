#!/usr/bin/env bash
# Logs docker in to every ECR registry the targets name, with the job's AWS
# credentials. BuildKit and buildx read the credentials docker writes.
# usage: registry-login.sh <targets.json>
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$here/lib.sh"

mapfile -t hosts < <(jq -r '.[] | .candidate, .release, .cache | split("/")[0]' "$1" | sort -u)
for host in "${hosts[@]}"; do
  [[ $host =~ ^[0-9]{12}\.dkr\.ecr\.([a-z0-9-]+)\.amazonaws\.com$ ]] ||
    die "$host is not an ECR registry, and ECR is the only registry this pipeline supports so far"
  aws ecr get-login-password --region "${BASH_REMATCH[1]}" |
    docker login --username AWS --password-stdin "$host" >&2
done
