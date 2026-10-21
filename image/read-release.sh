#!/usr/bin/env bash
# Reads what RELEASE already has under TAGS, before anything is written. If sha-<commit> names
# DIGEST, an earlier attempt of this commit released it and a re-run finishes it. If it names
# another image, an earlier release of this commit stands. Otherwise any tag naming another image
# fails, since a release tag can't be moved.
# Outputs found (true when sha-<commit> already names DIGEST), earlier, digest (the image the tags
# name), missing, and named (the tags that name it).
# env: TAGS, RELEASE, DIGEST, GITHUB_SHA
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

sha="sha-$GITHUB_SHA"
if ! grep -qxF "$sha" <<<"$TAGS"; then
  echo "::error::The tags must include $sha, which marks this commit as released."
  exit 1
fi

missing=() named=()
earlier="" found=false
target=$DIGEST
d=$("$here/digest-of.sh" "$RELEASE:$sha")
if [ -n "$d" ] && [ "$d" = "$DIGEST" ]; then
  found=true
elif [ -n "$d" ]; then
  earlier=$d target=$d
  echo "::notice::$RELEASE:$sha already names $earlier, an earlier release of this commit, which stands. Nothing was tagged with $DIGEST."
fi
while IFS= read -r name; do
  [ -n "$name" ] || continue
  d=$("$here/digest-of.sh" "$RELEASE:$name")
  if [ "$d" = "$target" ]; then
    named+=("$RELEASE:$name")
  elif [ -n "$earlier" ]; then
    continue
  elif [ -z "$d" ]; then
    missing+=("$RELEASE:$name") named+=("$RELEASE:$name")
  else
    echo "::error::$RELEASE:$name already names $d, not this image $target, and a release tag can't be moved. Every tag must be new to each release."
    exit 1
  fi
done <<<"$TAGS"

# Every line starts with the repository, so none can be the delimiter.
{
  echo "found=$found"
  echo "earlier=$earlier"
  echo "digest=$target"
  echo "missing<<EOF"
  if [ "${#missing[@]}" -gt 0 ]; then printf '%s\n' "${missing[@]}"; fi
  echo "EOF"
  echo "named<<EOF"
  if [ "${#named[@]}" -gt 0 ]; then printf '%s\n' "${named[@]}"; fi
  echo "EOF"
} >>"$GITHUB_OUTPUT"
