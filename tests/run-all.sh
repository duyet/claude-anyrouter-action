#!/usr/bin/env bash
#
# Run every test script. CI and local runs share this so a test that exists but
# is never executed cannot rot.

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

failed=0
for test in "$TESTS_DIR"/test-*.sh; do
  printf '\n===== %s =====\n' "$(basename "$test")"
  if ! bash "$test"; then
    failed=$((failed + 1))
  fi
done

printf '\n'
if [ "$failed" -eq 0 ]; then
  echo "all test suites passed"
else
  echo "$failed test suite(s) failed"
fi

exit "$failed"
