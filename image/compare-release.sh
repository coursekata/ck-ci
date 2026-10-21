#!/usr/bin/env bash
# Says whether the candidate is the baseline release apart from build metadata: for every platform,
# their configs must match once the created, revision and version labels, the image's creation time
# and each history entry's time are removed. What stays is what buildx's parsed config holds of the
# image itself: the layers' content digests, each instruction's history entry (a HEALTHCHECK shows
# only there) and the runtime settings, so a cached rebuild whose step times moved compares
# unchanged and a changed instruction does not. A config it cannot read is a change. Also outputs
# revision, the baseline's revision label, so the summary can name the commit it matched.
# env: CANDIDATE_REF, BASELINE_REF
set -euo pipefail

# A single-platform image parses as its config, a multi-platform one as a map of them by platform.
norm='if has("rootfs") then {(.os + "/" + .architecture + (if .variant then "/" + .variant else "" end)): .} else . end
  | map_values(del(.created)
    | .history |= (if . then map(del(.created)) else . end)
    | .config.Labels |= (if . then del(.["org.opencontainers.image.created"], .["org.opencontainers.image.revision"], .["org.opencontainers.image.version"]) else . end))'
revision_of='(if has("rootfs") then . else (to_entries | .[0].value) end) | .config.Labels["org.opencontainers.image.revision"] // ""'
inspect() { docker buildx imagetools inspect --format '{{json .Image}}' "$1"; }

unchanged=false revision=""
if raw_a=$(inspect "$CANDIDATE_REF") && raw_b=$(inspect "$BASELINE_REF"); then
  revision=$(jq -r "$revision_of" <<<"$raw_b")
  if [ "$(jq -S "$norm" <<<"$raw_a")" = "$(jq -S "$norm" <<<"$raw_b")" ]; then unchanged=true; fi
else
  echo "::warning::Could not read the configs of $CANDIDATE_REF and $BASELINE_REF, so the image releases as new."
fi
{
  echo "unchanged=$unchanged"
  echo "revision=$revision"
} >>"$GITHUB_OUTPUT"
