load helper

# A stand-in trivy first on PATH, recording its arguments and the git variables it was given, and
# exiting with TRIVY_EXIT.
fake_trivy() {
  mkdir -p bin
  cat >bin/trivy <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >trivy-args
for v in GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR; do
  eval "printf '%s=%s\n' $v \"\${$v-unset}\""
done >trivy-env
exit "${TRIVY_EXIT:-0}"
EOF
  chmod +x bin/trivy
  PATH="$PWD/bin:$PATH"
}

@test "trivy runs without the caller git hook environment" {
  fake_trivy
  GIT_DIR="$PWD/.git/worktrees/wt" GIT_WORK_TREE="$PWD" GIT_INDEX_FILE="$PWD/.git/worktrees/wt/index" \
    GIT_OBJECT_DIRECTORY="$PWD/.git/objects" GIT_COMMON_DIR="$PWD/.git" \
    hook trivy.sh
  assert_success
  run cat trivy-env
  assert_output "$(printf '%s=unset\n' GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR)"
}

@test "trivy scans from the root with the caller's arguments" {
  fake_trivy
  hook trivy.sh --skip-dirs '**/saga'
  assert_success
  run cat trivy-args
  assert_output "config --exit-code 1 --misconfig-scanners terraform --skip-dirs **/.terraform --skip-dirs **/saga ."
}

@test "a trivy failure fails the hook" {
  fake_trivy
  TRIVY_EXIT=1 hook trivy.sh
  assert_failure 1
}
