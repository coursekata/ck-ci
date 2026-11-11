load helper

# The bar's terraform_trivy entry, as written in pre-commit-config.yaml.
trivy_entry() {
  awk '/- id: terraform_trivy$/ { hook = 1 } hook && /^ *entry: / { sub(/^ *entry: /, ""); print; exit }' \
    "$HOOKS/pre-commit-config.yaml"
}

@test "trivy fetches modules without the caller git hook environment" {
  local entry
  entry=$(trivy_entry)
  [ -n "$entry" ]
  mkdir bin
  cat >bin/trivy <<'EOF'
#!/bin/sh
for v in GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE; do
  eval "printf '%s=%s\n' $v \"\${$v-unset}\""
done >trivy-env
EOF
  chmod +x bin/trivy
  GIT_DIR="$PWD/.git/worktrees/wt" GIT_WORK_TREE="$PWD" GIT_INDEX_FILE="$PWD/.git/worktrees/wt/index" \
    PATH="$PWD/bin:$PATH" run sh -c "$entry"
  assert_success
  run cat trivy-env
  assert_output "$(printf 'GIT_DIR=unset\nGIT_WORK_TREE=unset\nGIT_INDEX_FILE=unset')"
}
