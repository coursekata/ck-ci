#!/usr/bin/env bash
# Releases the head of the branch: reads the facts, has release.jq plan the writes, makes them in
# the plan's order, and writes the step summary and outputs. Only reads happen before the plan, so
# a run that stops before a write has changed nothing. crane does every registry read and write,
# with the login the caller made; a copy keeps the bytes and the digest.
# Outputs digest (this commit's release, or the latest release when unchanged; empty when no
# longer the head) and released.
# env: CANDIDATE, RELEASE, CACHE, DIGEST, TAGS, CACHE_DIGEST, ALWAYS_UPDATE_CACHE, TOKEN (read access
#      to the repository, or empty), and the job's GITHUB_* variables
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# rel <filter> [jq options]: runs a filter with release.jq's functions in scope.
rel() {
  local filter=$1
  shift
  jq -L "$here" "$@" "include \"release\"; $filter"
}

echo "::group::Read the facts"
# A tag's ref reads as its tag object, never the commit, so a run on one would release nothing and
# pass. A pull request's merge ref is a branch head GitHub keeps.
case $GITHUB_REF in
  refs/heads/* | refs/pull/*/merge) ;;
  *)
    echo "::error::$GITHUB_REF is not a branch, so nothing was released. release-action releases the head of a branch."
    exit 1
    ;;
esac
# The branch's head, read live; the token goes in a header through git's environment, never in a
# command line or URL. ls-remote exits 0 for a ref that does not exist.
if [ -n "${TOKEN:-}" ]; then
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraHeader
  GIT_CONFIG_VALUE_0="Authorization: Basic $(printf 'x-access-token:%s' "$TOKEN" | base64 | tr -d '\n')"
  export GIT_CONFIG_VALUE_0
fi
refs=$(git ls-remote "$GITHUB_SERVER_URL/$GITHUB_REPOSITORY" "$GITHUB_REF") || refs=""
branch_head=$(awk -v r="$GITHUB_REF" '$2 == r { print $1 }' <<<"$refs")
if [ -z "$branch_head" ]; then
  echo "::error::Could not read $GITHUB_REF's head from $GITHUB_REPOSITORY."
  exit 1
fi
facts=$(jq -n --arg h "$branch_head" --arg sha "$GITHUB_SHA" --arg release "$RELEASE" --arg repository "$CANDIDATE" \
  --arg candidate "$DIGEST" --arg run "run-$GITHUB_RUN_ID" '{head: ($h == $sha), branch_head: $h, release: $release,
    candidate_repository: $repository, candidate: $candidate, sha_tag: "sha-\($sha)", run_tag: $run, tags: [],
    latest: null, latest_tag: null, unchanged: null}')

if [ "$(jq .head <<<"$facts")" = true ]; then
  requested='[]'
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    d=$("$here/../lib/read-registry.sh" digest "$RELEASE:$name")
    requested=$(jq --arg n "$name" --arg d "$d" '. + [{name: $n, digest: ($d | select(. != "") // null)}]' <<<"$requested")
  done <<<"$TAGS"
  listed=$("$here/../lib/read-registry.sh" ls "$RELEASE")
  latest_run=$(rel '[inputs | select(. != "")] | latest_run // empty' -Rnr <<<"$listed")
  latest=null unchanged=null
  if [ -n "$latest_run" ]; then
    d=$("$here/../lib/read-registry.sh" digest "$RELEASE:$latest_run")
    latest=$(jq -n --arg t "$latest_run" --arg d "$d" '{tag: $t, digest: $d, commit: null}')
    # The build is compared only when its commit has no release yet: once sha-<commit> names one,
    # that release stands whatever the build is. A build with the latest release's own digest needs
    # no comparison either, since release.jq calls it unchanged.
    commit_release=$(jq -r --arg s "sha-$GITHUB_SHA" '.[] | select(.name == $s) | .digest // empty' <<<"$requested")
    if [ -z "$commit_release" ] && [ "$d" != "$DIGEST" ]; then
      if ! built=$("$here/../lib/read-configs.sh" "$CANDIDATE@$DIGEST") || ! released=$("$here/../lib/read-configs.sh" "$RELEASE@$d"); then
        echo "::error::Could not read the configs of $CANDIDATE@$DIGEST and $RELEASE@$d to compare them, so nothing was released."
        exit 1
      fi
      # shellcheck disable=SC2016 # $r is jq's, not the shell's
      compared=$(rel 'compare($r)' --argjson r "$released" <<<"$built")
      unchanged=$(jq .unchanged <<<"$compared")
      latest=$(jq --argjson c "$compared" '.commit = $c.revision' <<<"$latest")
    fi
  fi
  latest_tag=$("$here/../lib/read-registry.sh" digest "$RELEASE:latest")
  facts=$(jq --argjson tags "$requested" --argjson latest "$latest" --arg lt "$latest_tag" \
    --argjson unchanged "$unchanged" --arg cache "$CACHE" --arg cache_digest "$CACHE_DIGEST" \
    --argjson always "$([ "$ALWAYS_UPDATE_CACHE" = true ] && echo true || echo false)" \
    '. + {tags: $tags, latest: $latest, latest_tag: ($lt | select(. != "") // null), unchanged: $unchanged,
      cache: (if $cache != "" and $cache_digest != "" then {repository: $cache, digest: $cache_digest} else null end),
      always_update_cache: $always}' <<<"$facts")
fi
jq . <<<"$facts"
echo "::endgroup::"

plan=$(rel plan <<<"$facts")
jq . <<<"$plan"
if error=$(jq -er '.error' <<<"$plan"); then
  echo "::error::$error"
  exit 1
fi

# In the plan's order, so a run that stops between two writes leaves nothing a consumer reads: a
# release without its run tag is not the latest, and the head's next run finishes it.
while IFS=$'\t' read -r op from to; do
  crane "$op" "$from" "$to"
done < <(jq -r '.writes[] | [.op, .from, .to] | @tsv' <<<"$plan")

# shellcheck disable=SC2016 # $p is jq's, not the shell's
rel 'summary($p)' --argjson p "$plan" -r <<<"$facts" >>"$GITHUB_STEP_SUMMARY"
{
  echo "digest=$(jq -r '.target // ""' <<<"$plan")"
  echo "released=$(jq .released <<<"$plan")"
} >>"$GITHUB_OUTPUT"
