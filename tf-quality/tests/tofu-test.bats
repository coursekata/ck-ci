load helper

# module <dir> [<called dir>...]: a module that calls each given module, with one suite in tests/ that
# its output passes.
module() {
  local dir=$1
  shift
  mkdir -p "$dir/tests"
  printf 'output "name" {\n  value = "%s"\n}\n' "$dir" >"$dir/main.tf"
  local called
  for called in "$@"; do
    printf 'module "%s" {\n  source = "%s"\n}\n' "$(basename "$called")" "$(relative "$dir" "$called")" >>"$dir/main.tf"
  done
  suite "$dir/tests/main.tftest.hcl" "output.name == \"$dir\""
}

# relative <from> <to>: the path from one top-level-relative directory to another.
relative() {
  local up
  up=$(sed -E 's#[^/]+#..#g' <<<"$1")
  printf '%s/%s' "$up" "$2"
}

# suite <file> <condition>: a suite whose one assertion is the condition.
suite() {
  cat >"$1" <<EOF
run "holds" {
  command = plan

  assert {
    condition     = $2
    error_message = "the assertion failed"
  }
}
EOF
}

# The example the hook is built around: a calls b, b calls c, and d calls c.
chain() {
  module c
  module b c
  module a b
  module d c
}

@test "a change to a module runs every suite whose tree reaches it" {
  chain
  hook tofu-test.sh c/main.tf
  assert_success
  assert_line "tofu test in a"
  assert_line "tofu test in b"
  assert_line "tofu test in c"
  assert_line "tofu test in d"
}

@test "a change runs no suite whose tree does not reach it" {
  chain
  hook tofu-test.sh b/main.tf
  assert_success
  assert_line "tofu test in a"
  assert_line "tofu test in b"
  refute_line "tofu test in c"
  refute_line "tofu test in d"
}

@test "a change to a suite runs that suite alone" {
  chain
  hook tofu-test.sh a/tests/main.tftest.hcl
  assert_success
  assert_line "tofu test in a"
  refute_line "tofu test in b"
  refute_line "tofu test in c"
  refute_line "tofu test in d"
}

@test "a suite beside its module, not in tests/, runs" {
  mkdir -p e
  printf 'output "name" {\n  value = "e"\n}\n' >e/main.tf
  suite e/main.tftest.hcl 'output.name == "e"'
  hook tofu-test.sh e/main.tf
  assert_success
  assert_line "tofu test in e"
}

@test "a suite at the root runs" {
  module .
  hook tofu-test.sh main.tf
  assert_success
  assert_line "tofu test in ."
}

@test "a .tofutest suite runs" {
  mkdir -p f/tests
  printf 'output "name" {\n  value = "f"\n}\n' >f/main.tofu
  suite f/tests/main.tofutest.hcl 'output.name == "f"'
  hook tofu-test.sh f/main.tofu
  assert_success
  assert_line "tofu test in f"
}

@test "a change to a suite's helper module in tests/ runs that suite" {
  mkdir -p g/tests/fixture
  printf 'output "name" {\n  value = "g"\n}\n' >g/main.tf
  printf 'output "name" {\n  value = "fixture"\n}\n' >g/tests/fixture/main.tf
  cat >g/tests/main.tftest.hcl <<'EOF'
run "fixture" {
  command = plan

  module {
    source = "./tests/fixture"
  }

  assert {
    condition     = output.name == "fixture"
    error_message = "the fixture did not load"
  }
}
EOF
  hook tofu-test.sh g/tests/fixture/main.tf
  assert_success
  assert_line "tofu test in g"
}

@test "a failing suite fails the hook, and the other matched suites still run" {
  chain
  suite b/tests/main.tftest.hcl 'output.name == "not b"'
  hook tofu-test.sh c/main.tf
  assert_failure
  assert_line "tofu test failed in b"
  assert_line "tofu test in a"
  assert_line "tofu test in d"
}

@test "a suite whose module tree cannot be read fails the hook" {
  module h
  printf 'module "missing" {\n  source = "./does-not-exist"\n}\n' >>h/main.tf
  hook tofu-test.sh h/main.tf
  assert_failure
  assert_line "tofu get failed in h, so the files it reaches are unknown:"
}

@test "a suite in a downloaded module under .terraform is not this repository's" {
  module i
  module .terraform/modules/vendored
  hook tofu-test.sh i/main.tf .terraform/modules/vendored/main.tf
  assert_success
  assert_line "tofu test in i"
  refute_line --partial "vendored"
}

@test "a file no suite reaches runs nothing" {
  chain
  mkdir -p lone
  printf 'output "name" {\n  value = "lone"\n}\n' >lone/main.tf
  hook tofu-test.sh lone/main.tf
  assert_success
  assert_output ""
}

@test "a path with a space in it is matched" {
  module "with space"
  hook tofu-test.sh "with space/main.tf"
  assert_success
  assert_line "tofu test in with space"
}

@test "every file, as the workflow passes them, runs every suite" {
  chain
  hook tofu-test.sh a/main.tf a/tests/main.tftest.hcl b/main.tf b/tests/main.tftest.hcl \
    c/main.tf c/tests/main.tftest.hcl d/main.tf d/tests/main.tftest.hcl
  assert_success
  assert_line "tofu test in a"
  assert_line "tofu test in b"
  assert_line "tofu test in c"
  assert_line "tofu test in d"
}

@test "a change anywhere under a suite's tests/, such as a mock, runs that suite" {
  chain
  mkdir -p a/tests/mocks
  printf 'mock_resource "terraform_data" {}\n' >a/tests/mocks/data.tfmock.hcl
  hook tofu-test.sh a/tests/mocks/data.tfmock.hcl
  assert_success
  assert_line "tofu test in a"
  refute_line "tofu test in b"
}

@test "a change to a module's variables file runs the suites that reach it" {
  chain
  printf 'name = "c"\n' >c/terraform.tfvars
  hook tofu-test.sh c/terraform.tfvars
  assert_success
  assert_line "tofu test in b"
  assert_line "tofu test in c"
}

@test "a module tree it cannot read fails the hook, rather than run no suite" {
  chain
  mkdir -p bin
  printf '#!/bin/sh\nexit 3\n' >bin/jq
  chmod +x bin/jq
  PATH="$PWD/bin:$PATH" hook tofu-test.sh c/main.tf
  assert_failure
  assert_line "the module tree of a could not be read"
}

@test "a tofu get failure shows tofu's own error" {
  module h
  printf 'module "missing" {\n  source = "./does-not-exist"\n}\n' >>h/main.tf
  hook tofu-test.sh h/main.tf
  assert_failure
  assert_output --partial "does-not-exist"
}

@test "nothing under .git is taken for a suite" {
  module a
  mkdir -p .git/stale/tests
  printf 'module "missing" {\n  source = "./does-not-exist"\n}\n' >.git/stale/main.tf
  suite .git/stale/tests/main.tftest.hcl 'output.name == "stale"'
  hook tofu-test.sh a/main.tf
  assert_success
  assert_line "tofu test in a"
}

@test "module downloads ignore the caller git hook environment" {
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
  module upstream
  git -C upstream init -q
  git -C upstream add main.tf
  git -C upstream -c user.name=Test -c user.email=test@example.invalid -c commit.gpgsign=false commit -qm fixture
  module consumer
  printf 'module "remote" {\n  source = "git::file://%s/upstream"\n}\n' "$PWD" >>consumer/main.tf
  GIT_DIR="$PWD/nonexistent.git" GIT_WORK_TREE="$PWD/not-a-worktree" \
    GIT_INDEX_FILE="$PWD/not-an-index" GIT_ALLOW_PROTOCOL=file \
    hook tofu-test.sh consumer/main.tf
  assert_success
  assert_line "tofu test in consumer"
}
