#!/usr/bin/env bash
# Fails on a committed testing = true. var.testing configures the aws provider offline so a root plans
# without credentials; shipped enabled, it disarms the account-guard preamble, whose job is to fail a
# plan run under the wrong credential, so the guard would fail open, silently. Tests set it in tests/,
# which the hook does not pass here.
set -uo pipefail

[ "$#" -gt 0 ] || exit 0
rc=0
hits=$(grep -nHE 'testing"?[[:space:]]*[=:][[:space:]]*true' -- "$@") || rc=$?
if [ "$rc" -eq 0 ]; then
  echo "$hits"
  echo "var.testing must never be true in committed config. It weakens the provider and disarms account-guard. Tests set it in tests/ only."
  exit 1
elif [ "$rc" -ne 1 ]; then
  echo "grep could not read every file, so the testing guard cannot pass."
  exit 1
fi
