#!/usr/bin/env bash
# One trivy config scan from the root, so trivy reads the repository's .trivyignore itself and a
# repository without one still scans. Only OpenTofu misconfigurations, and none in the modules under
# .terraform, which their own repositories gate. Arguments are passed on to trivy.
set -uo pipefail

# git exports its repository variables to a hook, and the git that trivy fetches a module source with
# would inherit them and work on the committing repository instead.
while IFS= read -r v; do
  unset "$v"
done < <(git rev-parse --local-env-vars)

exec trivy config --exit-code 1 --misconfig-scanners terraform --skip-dirs '**/.terraform' "$@" .
