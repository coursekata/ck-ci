# Loaded by every image test file.
bats_require_minimum_version 1.5.0
# bats sets its own BATS_LIB_PATH, so the usual install folders are added to it, not defaulted.
export BATS_LIB_PATH="$BATS_LIB_PATH:/usr/lib:/opt/homebrew/lib:/usr/local/lib"
bats_load_library bats-support
bats_load_library bats-assert

# shellcheck disable=SC2034 # read by the test files that load this one
SCRIPTS="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
