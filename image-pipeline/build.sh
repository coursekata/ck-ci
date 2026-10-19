#!/usr/bin/env bash
# Builds the configured images in one bake call, so shared stages build once.
#
# pr: a pull request builds every image and every test target and keeps nothing.
# Nothing is pushed and no cache is exported, and each test stage re-runs rather
# than matching a cache.
# push: a push to the default branch builds the images only. Each is pushed by
# digest to its candidate repository, and its cache beside it under the tag
# cache-<run id>-<run attempt>: a cache export always names a tag, and the
# candidate repository's tags are immutable, so each attempt needs its own. Both
# digests come from bake's metadata, so no tag is read back. Prints them, for the
# test step and the release job.
#
# Either mode imports the image's release cache, by the digest its tag names, when
# the run is told to import it. An image with no release cache yet starts cold. A
# push told not to import reports fresh: true, so its release replaces the cache even
# for a commit already released.
# usage: build.sh <targets.json> <resolved.json> <pr|push> <import cache: true|false> <run id> <run attempt> <work dir>
#   push prints {"fresh", "targets": {<target>: {"digest", "cache_digest"}}}
# Run from the repository root.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$here/lib.sh"

targets=$1 resolved=$2 mode=$3 import=$4 run=$5 attempt=$6 work=$7
case "$mode" in pr | push) ;; *) die "mode must be pr or push, got $mode" ;; esac
case "$import" in true | false) ;; *) die "import must be true or false, got $import" ;; esac
[[ $run =~ ^[0-9]+$ ]] || die "the run id must be a number, got $run"
[[ $attempt =~ ^[0-9]+$ ]] || die "the run attempt must be a number, got $attempt"
mkdir -p "$work"

# check_kind <target> <ref> <platforms json>: a single-platform push must be one image
# manifest, and a multi-platform push an index with no attestation entries.
check_kind() {
  local manifest media
  manifest=$(docker buildx imagetools inspect --raw "$2") || die "$1: cannot read $2"
  media=$(jq -r .mediaType <<<"$manifest")
  if [ "$(jq length <<<"$3")" -le 1 ]; then
    case "$media" in
      application/vnd.oci.image.manifest.v1+json | application/vnd.docker.distribution.manifest.v2+json) ;;
      *) die "$1: $2 is $media, but a single-platform build must push one image manifest" ;;
    esac
  else
    case "$media" in
      application/vnd.oci.image.index.v1+json | application/vnd.docker.distribution.manifest.list.v2+json) ;;
      *) die "$1: $2 is $media, but a multi-platform build must push an index" ;;
    esac
    jq -e '[.manifests[] | select(.platform.os == "unknown")] | length == 0' <<<"$manifest" >/dev/null ||
      die "$1: $2 carries attestation entries; attestations must be off"
  fi
}

# cache_from <cache repository>: the bake cache-from list for the release cache,
# pinned to the digest its tag names now.
cache_from() {
  local d rc=0
  if [ "$import" = false ]; then
    echo '[]'
    return
  fi
  d=$(digest_of "$1:$RELEASE_CACHE_TAG") || rc=$?
  case $rc in
    0) jq -nc --arg r "$1@$d" '["type=registry,ref=\($r)"]' ;;
    3)
      echo "no release cache at $1:$RELEASE_CACHE_TAG yet; this build starts cold" >&2
      echo '[]'
      ;;
    *) die "could not read the release cache $1:$RELEASE_CACHE_TAG" ;;
  esac
}

overrides='{"target": {}}'
names=()
while IFS=$'\t' read -r t test candidate cache; do
  from=$(cache_from "$cache")
  if [ "$mode" = push ]; then
    overrides=$(jq -c --arg t "$t" --arg c "$candidate" --arg tag "cache-$run-$attempt" --argjson from "$from" '
      .target[$t] = {
        call: "build",
        output: ["type=image,name=\($c),push-by-digest=true,name-canonical=true,push=true"],
        "cache-from": $from,
        "cache-to": ["type=registry,ref=\($c):\($tag),mode=max,oci-mediatypes=true,image-manifest=true"]
      }' <<<"$overrides")
    names+=("$t")
  else
    stage=$(jq -r --arg t "$test" '.target[$t].target' "$resolved")
    overrides=$(jq -c --arg t "$t" --arg test "$test" --arg stage "$stage" --argjson from "$from" '
      .target[$t] = {call: "build", output: ["type=cacheonly"], "cache-from": $from}
      | .target[$test] = {call: "build", output: ["type=cacheonly"], "cache-from": $from, "no-cache-filter": [$stage]}' <<<"$overrides")
    names+=("$t" "$test")
  fi
done < <(jq -r '.[] | [.target, .test, .candidate, .cache] | @tsv' "$targets")

printf '%s\n' "$overrides" >"$work/build-overrides.json"
bake_clean -f "$resolved" -f "$work/build-overrides.json" \
  --metadata-file "$work/metadata.json" --progress=plain "${names[@]}" >&2 ||
  die "the build of ${names[*]} failed"

[ "$mode" = push ] || exit 0

out='{}'
while IFS=$'\t' read -r t candidate; do
  digest=$(jq -r --arg t "$t" '.[$t]["containerimage.digest"] // ""' "$work/metadata.json")
  [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || die "$t: the build reported no image digest"
  # BuildKit reports the exported cache as a descriptor serialized to a string.
  cache_digest=$(jq -r --arg t "$t" '.[$t]["cache.manifest"] // "{}" | fromjson | .digest // ""' "$work/metadata.json") ||
    die "$t: the build's cache manifest is not a descriptor"
  [[ $cache_digest =~ ^sha256:[0-9a-f]{64}$ ]] || die "$t: the build reported no cache manifest"
  check_kind "$t" "$candidate@$digest" "$(jq -c --arg t "$t" '.target[$t].platforms // []' "$resolved")"
  out=$(jq -c --arg t "$t" --arg d "$digest" --arg cd "$cache_digest" '.[$t] = {digest: $d, cache_digest: $cd}' <<<"$out")
done < <(jq -r '.[] | [.target, .candidate] | @tsv' "$targets")

if [ "$import" = true ]; then fresh=false; else fresh=true; fi
jq -n --argjson f "$fresh" --argjson t "$out" '{fresh: $f, targets: $t}'
