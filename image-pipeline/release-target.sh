#!/usr/bin/env bash
# Releases one target this run built and tested. The image is copied by digest to the
# release repository as sha-<commit> and run-<run id>, then its cache by digest to the
# cache repository's cache tag. It never builds, and both candidate digests are
# checked before anything is written.
#
# sha-<commit> already present means an earlier run or attempt released this commit.
# If it names this run's digest, this finishes whatever that attempt left. If it
# names another, the first release stands. A build that imported the cache leaves the
# cache where it is; one built without it still replaces the cache, so the next build
# reuses its layers.
# usage: release-target.sh <targets.json> <build.json> <target> <commit sha> <run id>
#   prints {"target", "digest" (the commit's release), "copied": [...], "note"}
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$here/lib.sh"

targets=$1 build=$2 t=$3 sha=$4 run=$5
[[ $sha =~ ^[0-9a-f]{40}$ ]] || die "the commit must be a full commit SHA, got $sha"
[[ $run =~ ^[0-9]+$ ]] || die "the run id must be a number, got $run"

jq -e --slurpfile c "$targets" '(.targets | keys) == ([$c[0][].target] | sort)' "$build" >/dev/null ||
  die "the build's targets $(jq -c '.targets | keys' "$build") are not the configured targets $(jq -c '[.[].target]' "$targets")"

IFS=$'\t' read -r candidate release cache < <(jq -r --arg t "$t" \
  '.[] | select(.target == $t) | [.candidate, .release, .cache] | @tsv' "$targets") ||
  die "$t is not a configured target"
IFS=$'\t' read -r digest cache_digest fresh < <(jq -r --arg t "$t" \
  '[.targets[$t].digest, .targets[$t].cache_digest, (.fresh | tostring)] | @tsv' "$build")

[[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || die "$t: the build's image digest '$digest' is not a digest"
[[ $cache_digest =~ ^sha256:[0-9a-f]{64}$ ]] || die "$t: the build's cache digest '$cache_digest' is not a digest"
case "$fresh" in true | false) ;; *) die "the build's fresh '$fresh' is not true or false" ;; esac

emit() {
  jq -cn --arg t "$t" --arg d "$1" --argjson copied "$2" --arg note "${3:-}" \
    '{target: $t, digest: $d, copied: $copied, note: $note}'
}

# state <ref>: prints present:<digest> or absent, and stops the job on any other answer.
state() {
  local d rc=0
  d=$(digest_of "$1") || rc=$?
  case $rc in
    0) echo "present:$d" ;;
    3) echo absent ;;
    *) die "could not read $1" ;;
  esac
}

# copy <source by digest> <tag>: copies the manifest and its blobs unchanged. By
# default buildx wraps a single-platform image in a new index, which would give the
# tag other bytes than the ones tested.
copy() { docker buildx imagetools create --prefer-index=false --tag "$2" "$1" >&2; }

sha_ref="$release:sha-$sha"
run_ref="$release:run-$run"
cache_ref="$cache:$RELEASE_CACHE_TAG"

# stands: the commit's release, when an earlier run released another image for it.
stands=
released=$(state "$sha_ref")
case "$released" in
  present:*)
    if [ "${released#present:}" != "$digest" ]; then
      stands=${released#present:}
      if ! $fresh; then
        emit "$stands" '[]' "$sha_ref was released as $stands by an earlier run, and that release stands. This attempt rebuilt the image as $digest; the cache stays where it is."
        exit 0
      fi
    fi
    copy_image=false
    ;;
  absent) copy_image=true ;;
esac

if [ -n "$stands" ]; then
  # run-<run id> names what a run released, and this one releases no image.
  copy_run=false
else
  tagged=$(state "$run_ref")
  case "$tagged" in
    present:*)
      [ "${tagged#present:}" = "$digest" ] ||
        die "$run_ref already names ${tagged#present:}, not this run's image $digest"
      copy_run=false
      ;;
    absent) copy_run=true ;;
  esac
fi

cached=$(state "$cache_ref")
if [ "$cached" = "present:$cache_digest" ]; then copy_cache=false; else copy_cache=true; fi

if $copy_image || $copy_run; then
  s=$(state "$candidate@$digest")
  [ "$s" = "present:$digest" ] ||
    die "the tested image $candidate@$digest is gone, expired or never pushed. The release does not build."
fi
if $copy_cache; then
  s=$(state "$candidate@$cache_digest")
  [ "$s" = "present:$cache_digest" ] || die "the run's cache $candidate@$cache_digest is gone"
fi

copied='[]'
if $copy_image; then
  copy "$candidate@$digest" "$sha_ref"
  copied=$(jq -c '. + ["image"]' <<<"$copied")
fi
if $copy_run; then
  copy "$candidate@$digest" "$run_ref"
  copied=$(jq -c '. + ["run"]' <<<"$copied")
fi
if $copy_cache; then
  copy "$candidate@$cache_digest" "$cache_ref"
  copied=$(jq -c '. + ["cache"]' <<<"$copied")
fi

checks=("$cache_ref $cache_digest")
[ -n "$stands" ] || checks=("$sha_ref $digest" "$run_ref $digest" "${checks[@]}")
for pair in "${checks[@]}"; do
  read -r ref want <<<"$pair"
  landed=$(state "$ref")
  [ "$landed" = "present:$want" ] || die "$ref reads back as ${landed#present:}, but this run's is $want"
done

if [ -n "$stands" ]; then
  emit "$stands" "$copied" "$sha_ref was released as $stands, and that release stands. This run rebuilt the image without the cache as $digest. Its cache is now the release cache, so the next build reuses those layers."
else
  emit "$digest" "$copied"
fi
