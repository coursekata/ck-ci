#!/usr/bin/env bash
# Runs every tofu test suite whose module tree holds one of the given files. tofu get resolves each
# suite's tree, test helper modules included, so a change inside a module runs the suite of every
# module that calls it, however deep, and no other. Given every file, it runs every suite.
set -uo pipefail

# The folders the given files sit in, as absolute paths.
changed=""
for f in "$@"; do
  d=$(cd "$(dirname "$f")" && pwd -P) || continue
  changed+="$d"$'\n'
done

# Every folder that owns a suite, beside its module or in its tests/. A module downloaded into
# .terraform is another repository's, so its suites are not run here.
suites=$(find . \( -name .terraform -o -name .git \) -prune -o -type f \
  \( -name '*.tftest.hcl' -o -name '*.tftest.json' -o -name '*.tofutest.hcl' -o -name '*.tofutest.json' \) \
  -print | sed -E 's#(/tests)?/[^/]+$##; s#^\./##' | sort -u)

# tofu reads no input here, so each call gets none rather than the rest of the suite list.
rc=0
while IFS= read -r s; do
  [ -n "$s" ] || continue
  if ! out=$(tofu -chdir="$s" get -no-color </dev/null 2>&1); then
    echo "tofu get failed in $s, so the files it reaches are unknown:"
    echo "$out"
    rc=1
    continue
  fi
  if ! dirs=$(jq -r '.Modules[].Dir' "$s/.terraform/modules/modules.json"); then
    echo "the module tree of $s could not be read"
    rc=1
    continue
  fi

  # A change anywhere under the suite's own tests/, such as a mock, counts as well.
  own=$(cd "$s" && pwd -P)
  hit=""
  while IFS= read -r c; do
    case "$c/" in "$own/tests/"*) hit=1 && break ;; esac
  done <<<"$changed"
  while [ -z "$hit" ] && IFS= read -r dir; do
    case "$dir" in .terraform/*) continue ;; esac
    abs=$(cd "$s/$dir" && pwd -P) || continue
    if grep -Fxq -- "$abs" <<<"$changed"; then hit=1; fi
  done <<<"$dirs"
  [ -n "$hit" ] || continue

  echo "tofu test in $s"
  if ! tofu -chdir="$s" init -backend=false -input=false -no-color </dev/null >/dev/null; then
    echo "tofu init failed in $s"
    rc=1
  elif ! tofu -chdir="$s" test -no-color </dev/null; then
    echo "tofu test failed in $s"
    rc=1
  fi
done <<<"$suites"
exit "$rc"
