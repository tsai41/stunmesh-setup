#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

for test_file in tests/*_test.sh; do
  echo "==> $test_file"
  bash "$test_file"
done
