# Each test runs a hook script from the root of a small tree it writes into its own temp directory,
# with real tofu and only OpenTofu's built-in provider, so nothing comes from the network.
bats_require_minimum_version 1.5.0
# bats sets its own BATS_LIB_PATH, so the usual install folders are added to it, not defaulted.
export BATS_LIB_PATH="$BATS_LIB_PATH:/usr/lib:/opt/homebrew/lib:/usr/local/lib"
bats_load_library bats-support
bats_load_library bats-assert

HOOKS="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

setup() {
  cd "$BATS_TEST_TMPDIR" || return
}

# hook <script> <file>...: runs that hook script on the files, as prek would.
hook() {
  local script=$1
  shift
  run bash "$HOOKS/$script" "$@"
}
