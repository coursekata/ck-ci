#!/usr/bin/env bash
# Runs every image-pipeline unit test file. The integration test needs Docker and a
# registry, so CI runs it as a job of its own.
set -euo pipefail
dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
failed=0
for f in "$dir"/test_*.sh; do
  echo "== ${f##*/}"
  bash "$f" || failed=1
done
exit "$failed"
