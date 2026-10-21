#!/usr/bin/env bash
# Writes the release's step summary: the digest the tags name and every tag that names it, or,
# for an image unchanged from the newest release, which release that was and that nothing was
# released or tagged. A release with no baseline says so, since a caller whose lookup wrongly
# yields nothing would otherwise release as new on every merge without a trace.
# env: RELEASED, EARLIER, UNCHANGED, DIGEST, BASELINE, BASELINE_COMMIT, CACHE_MOVED, NAMED
set -euo pipefail

lead="Released \`$RELEASED\`."
note=""
if [ "$UNCHANGED" = true ]; then
  if [ -n "$BASELINE_COMMIT" ]; then
    lead="Unchanged from the newest release, sha-$BASELINE_COMMIT (\`$RELEASED\`), apart from build metadata. Nothing was released or tagged."
  else
    lead="Unchanged from the newest release \`$RELEASED\` apart from build metadata. Nothing was released or tagged."
  fi
elif [ -n "$EARLIER" ]; then
  note="An earlier release stands. Nothing was tagged with $DIGEST."
elif [ -z "$BASELINE" ]; then
  note="No baseline was given, so this image releases as new."
fi
if [ "$CACHE_MOVED" = true ]; then note="${note:+$note }This build's cache is now current."; fi
{
  echo '### Image release'
  echo
  echo "$lead${note:+ $note}"
  echo
  echo '| Tag |'
  echo '|---|'
  while IFS= read -r ref; do
    if [ -n "$ref" ]; then echo "| $ref |"; fi
  done <<<"$NAMED"
} >>"$GITHUB_STEP_SUMMARY"
