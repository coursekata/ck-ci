# Loaded by every image test file. The fake docker in bin/ comes first on PATH, and every test gets
# a fresh directory that the fake answers from and logs its calls to, holding the step's output and
# summary files too.
bats_require_minimum_version 1.5.0
# bats sets its own BATS_LIB_PATH, so the usual install folders are added to it, not defaulted.
export BATS_LIB_PATH="$BATS_LIB_PATH:/usr/lib:/opt/homebrew/lib:/usr/local/lib"
bats_load_library bats-support
bats_load_library bats-assert

# shellcheck disable=SC2034 # read by the test files that load this one
SCRIPTS="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
PATH="$BATS_TEST_DIRNAME/bin:$PATH"

fresh_state() {
  export FAKE_STATE="$BATS_TEST_TMPDIR/state"
  export GITHUB_OUTPUT="$FAKE_STATE/output" GITHUB_STEP_SUMMARY="$FAKE_STATE/summary"
  mkdir -p "$FAKE_STATE"
  : >"$FAKE_STATE/calls"
  : >"$GITHUB_OUTPUT"
  : >"$GITHUB_STEP_SUMMARY"
}

# registry_has <ref> <digest>: the fake registry resolves ref to digest.
registry_has() { printf '%s %s\n' "$1" "$2" >>"$FAKE_STATE/registry"; }

# registry_fails <ref> <message>: the fake registry answers ref with an error.
registry_fails() { printf '%s %s\n' "$1" "$2" >>"$FAKE_STATE/registry-errors"; }

# image_config <ref> <json>: what the fake registry answers for <ref>'s parsed config.
image_config() { mkdir -p "$FAKE_STATE/config" && printf '%s\n' "$2" >"$FAKE_STATE/config/$(tr '/:@' '___' <<<"$1")"; }

# bake_prints <json>: what the fake bake prints for --print.
bake_prints() { printf '%s\n' "$1" >"$FAKE_STATE/bake-print"; }

# calls: everything the fakes were asked to do, one line each.
calls() { cat "$FAKE_STATE/calls"; }

# step_output <name>: the value the step set for name, in either the name=value or name<<EOF form.
step_output() {
  awk -v n="$1" '
    d != "" { if ($0 == d) { d = ""; exit } print; next }
    index($0, n "=") == 1 { print substr($0, length(n) + 2); exit }
    index($0, n "<<") == 1 { d = substr($0, length(n) + 3) }
  ' "$GITHUB_OUTPUT"
}

summary() { cat "$GITHUB_STEP_SUMMARY"; }
