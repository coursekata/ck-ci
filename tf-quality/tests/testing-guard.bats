load helper

@test "the testing guard passes testing left off" {
  printf 'variable "testing" {\n  type    = bool\n  default = false\n}\n' >variables.tf
  printf 'testing = false\n' >prod.tfvars
  hook testing-guard.sh variables.tf prod.tfvars
  assert_success
}

@test "the testing guard fails testing = true in configuration" {
  printf 'module "m" {\n  source  = "./m"\n  testing = true\n}\n' >main.tofu
  hook testing-guard.sh main.tofu
  assert_failure
  assert_output --partial "main.tofu:3:"
}

@test "the testing guard fails testing = true in a tfvars file" {
  printf 'testing = true\n' >prod.tfvars
  hook testing-guard.sh prod.tfvars
  assert_failure
  assert_output --partial "prod.tfvars:1:"
}

@test "the testing guard fails testing true in JSON variables" {
  printf '{"testing": true}\n' >prod.tfvars.json
  hook testing-guard.sh prod.tfvars.json
  assert_failure
  assert_output --partial "prod.tfvars.json:1:"
}

@test "the testing guard fails when it cannot read a file" {
  hook testing-guard.sh missing.tfvars
  assert_failure
  assert_output --partial "could not read"
}
