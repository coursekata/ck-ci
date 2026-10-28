#!/usr/bin/env bash
# Prints an image's configs as one JSON object keyed by platform (os/architecture[/variant]): one
# entry for a single-platform image, one per platform for an index, whose attestation entries are
# left out. Fails when the registry cannot be read.
# usage: read-configs.sh <repository>@<digest>
set -euo pipefail
ref=$1
repo=${ref%@*}
manifest=$(crane manifest "$ref")
if jq -e '.manifests' <<<"$manifest" >/dev/null; then
  children=$(jq -r '.manifests[] | select(.platform.os != "unknown") | .digest' <<<"$manifest")
else
  children=${ref##*@}
fi
configs='{}'
while IFS= read -r d; do
  config=$(crane config "$repo@$d")
  configs=$(jq --argjson c "$config" '. + {($c | [.os, .architecture, .variant // empty] | join("/")): $c}' <<<"$configs")
done <<<"$children"
printf '%s\n' "$configs"
