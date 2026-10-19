#!/usr/bin/env bash
# Helpers for the image-pipeline unit tests. A test file sources this, defines
# functions named test_*, and ends with run_tests. Each test runs in its own
# subshell with errexit on, so the first failed assertion ends that test.

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PIPELINE_DIR=$(cd "$TESTS_DIR/.." && pwd)
FAKES="$TESTS_DIR/bin"
export TESTS_DIR PIPELINE_DIR

fail() {
  echo "    $*" >&2
  exit 1
}

assert_eq() { [ "$1" = "$2" ] || fail "${3:-mismatch}: expected [$1], got [$2]"; }
assert_contains() { case "$1" in *"$2"*) ;; *) fail "${3:-missing text}: [$2] not in [$1]" ;; esac; }
assert_not_contains() { case "$1" in *"$2"*) fail "${3:-unexpected text}: [$2] in [$1]" ;; esac; }
assert_status() { [ "$1" = "$STATUS" ] || fail "exit status: expected $1, got $STATUS; stderr: $ERR"; }

# run <command...>: runs with the fakes first on PATH, and sets STATUS, OUT and ERR.
run() {
  local o e
  o=$(mktemp)
  e=$(mktemp)
  set +e
  PATH="$FAKES:$PATH" "$@" >"$o" 2>"$e"
  STATUS=$?
  set -e
  # shellcheck disable=SC2034 # read by the test files that source this one
  OUT=$(cat "$o")
  ERR=$(cat "$e")
}

# fresh_state: a directory the fakes answer from and log their calls to. It is HOME
# too, because bake runs under env -i, which keeps HOME but not FAKE_STATE.
fresh_state() {
  FAKE_STATE=$(mktemp -d)
  HOME=$FAKE_STATE
  export FAKE_STATE HOME
  : >"$FAKE_STATE/calls"
}

# registry_has <ref> <digest>: the fake registry resolves ref to digest.
registry_has() { printf '%s %s\n' "$1" "$2" >>"$FAKE_STATE/registry"; }

# registry_fails <ref> <message>: the fake registry answers ref with an error.
registry_fails() { printf '%s %s\n' "$1" "$2" >>"$FAKE_STATE/registry-errors"; }

# calls: everything the fakes were asked to do, one line each.
calls() { cat "$FAKE_STATE/calls"; }

# gh_answers <api path> <body> [n]: the fake gh's answer to `gh api <path>`, or to
# its nth call of that path. A body of __fail__ makes that call fail.
gh_answers() {
  mkdir -p "$FAKE_STATE/gh"
  printf '%s\n' "$2" >"$FAKE_STATE/gh/$(printf '%s' "$1" | tr '/?&=' '____')${3:+.$3}"
}

# new_repo: an empty git repository in a new directory, made the working directory.
new_repo() {
  REPO=$(mktemp -d)
  cd "$REPO"
  git init -q -b main
  git config user.email test@example.invalid
  git config user.name test
  git config commit.gpgsign false
}

commit_all() { git add -A && git commit -qm "${1:-change}"; }

run_tests() {
  local t rc failed=0
  for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
    set +e
    (
      set -e
      "$t"
    )
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then echo "ok   ${t#test_}"; else echo "FAIL ${t#test_}"; failed=1; fi
  done
  return "$failed"
}
