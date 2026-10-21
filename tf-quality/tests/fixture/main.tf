# What tf-quality.yml checks when this repository's CI calls it: one module with one suite, on
# OpenTofu's built-in provider, so every check has something to read.
terraform {
  required_version = ">= 1.11.6"
}

variable "name" {
  description = "Passed through to the output."
  type        = string
  default     = "fixture"
}

resource "terraform_data" "this" {
  input = var.name
}

output "name" {
  description = "The name, as the resource holds it."
  value       = terraform_data.this.input
}
