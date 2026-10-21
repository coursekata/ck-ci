load helper

clean() { printf 'resource "terraform_data" "x" {\n  input = 1\n}\n' >"$1"; }

@test "the ban passes clean configuration" {
  clean main.tf
  clean other.tofu
  hook ban.sh main.tf other.tofu
  assert_success
}

@test "the ban passes when given no files" {
  hook ban.sh
  assert_success
}

@test "the ban fails an external data source" {
  clean main.tf
  printf 'data "external" "x" {\n  program = ["true"]\n}\n' >bad.tofu
  hook ban.sh main.tf bad.tofu
  assert_failure
  assert_output --partial 'bad.tofu:1:data "external" "x" {'
}

@test "the ban fails a provisioner" {
  printf 'resource "terraform_data" "x" {\n  provisioner "local-exec" {\n    command = "true"\n  }\n}\n' >main.tf
  hook ban.sh main.tf
  assert_failure
  assert_output --partial 'main.tf:2:'
}

@test "the ban fails a provider endpoints override" {
  printf 'provider "aws" {\n  endpoints {\n    s3 = "http://localhost"\n  }\n}\n' >main.tf
  hook ban.sh main.tf
  assert_failure
  assert_output --partial 'main.tf:2:'
}

@test "the ban fails JSON configuration, which it cannot read" {
  clean main.tf
  printf '{"resource": {}}\n' >main.tf.json
  hook ban.sh main.tf main.tf.json
  assert_failure
  assert_output --partial "main.tf.json"
}

@test "the ban reads a path with special characters" {
  mkdir -p "a dir"
  printf 'data "external" "x" {\n  program = ["true"]\n}\n' >"a dir/b\"ad.tf"
  hook ban.sh "a dir/b\"ad.tf"
  assert_failure
  assert_output --partial 'data "external"'
}

@test "the ban fails when it cannot read a file" {
  clean main.tf
  hook ban.sh main.tf missing.tf
  assert_failure
  assert_output --partial "could not read"
}
