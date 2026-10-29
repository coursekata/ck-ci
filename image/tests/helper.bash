# Loaded by every image test file.
bats_require_minimum_version 1.5.0
# bats sets its own BATS_LIB_PATH, so the usual install folders are added to it, not defaulted.
export BATS_LIB_PATH="$BATS_LIB_PATH:/usr/lib:/opt/homebrew/lib:/usr/local/lib"
bats_load_library bats-support
bats_load_library bats-assert

TESTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034 # read by the test files that load this one
SCRIPTS="$(cd "$TESTS/.." && pwd)"

# step_output <name>: the value the step set for name, in either the name=value or name<<EOF form.
step_output() {
  awk -v n="$1" '
    d != "" { if ($0 == d) { d = ""; exit } print; next }
    index($0, n "=") == 1 { print substr($0, length(n) + 2); exit }
    index($0, n "<<") == 1 { d = substr($0, length(n) + 3) }
  ' "$GITHUB_OUTPUT"
}
