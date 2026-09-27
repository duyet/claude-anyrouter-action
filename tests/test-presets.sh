#!/usr/bin/env bash
#
# Behavioural tests for the task presets.
#
# Runs scripts/resolve-preset.sh against a throwaway step-output file and
# asserts on the prompt, CLI arguments, and permissions each preset resolves to.

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"

# shellcheck source=helpers.sh
. "$TESTS_DIR/helpers.sh"

SCRIPT="$REPO_ROOT/scripts/resolve-preset.sh"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

COUNTER=0

# run_preset [KEY=VALUE ...]
# Sets OUT, STATUS, and points OUTPUT_FILE at the file the script wrote.
run_preset() {
  COUNTER=$((COUNTER + 1))
  OUTPUT_FILE="$TMP_ROOT/out.$COUNTER"
  : >"$OUTPUT_FILE"

  OUT="$(env -i \
    PATH="$PATH" \
    GITHUB_OUTPUT="$OUTPUT_FILE" \
    PRESET="default" \
    "$@" \
    bash "$SCRIPT" 2>&1)"
  STATUS=$?
}

echo "== default preset is a pass-through =="
run_preset
assert_status 0 "$STATUS" "succeeds"
assert_eq "" "$(print_env_var "$OUTPUT_FILE" prompt)" "no prompt is injected"
assert_eq "" "$(print_env_var "$OUTPUT_FILE" claude_args)" "no CLI args are injected"
assert_eq "" "$(print_env_var "$OUTPUT_FILE" additional_permissions)" "no permissions are injected"

run_preset PRESET=""
assert_status 0 "$STATUS" "an empty preset name is accepted"

echo
echo "== caller values are forwarded unchanged =="
run_preset PRESET_PROMPT="Do the thing" PRESET_CLAUDE_ARGS="--max-turns 3" \
  PRESET_ADDITIONAL_PERMISSIONS="issues: write"
assert_eq "Do the thing" "$(print_env_var "$OUTPUT_FILE" prompt)" "the prompt is forwarded"
assert_eq "--max-turns 3" "$(print_env_var "$OUTPUT_FILE" claude_args)" "the CLI args are forwarded"
assert_eq "issues: write" "$(print_env_var "$OUTPUT_FILE" additional_permissions)" \
  "the permissions are forwarded"

echo
echo "== review preset =="
run_preset PRESET=review
assert_status 0 "$STATUS" "succeeds"
assert_contains "$(print_env_var "$OUTPUT_FILE" prompt)" "Review this pull request" \
  "the review prompt is applied"
assert_contains "$(print_env_var "$OUTPUT_FILE" prompt)" "Do not modify any files" \
  "the review prompt is read-only"
assert_contains "$(print_env_var "$OUTPUT_FILE" claude_args)" "--max-turns" \
  "the review preset sets a turn limit"
assert_eq "actions: read" "$(print_env_var "$OUTPUT_FILE" additional_permissions)" \
  "the review preset can read CI results"

echo
echo "== fix-ci preset =="
run_preset PRESET=fix-ci
assert_status 0 "$STATUS" "succeeds"
assert_contains "$(print_env_var "$OUTPUT_FILE" prompt)" "gh run list" \
  "the fix-ci prompt inspects the failing runs"
assert_eq "actions: read" "$(print_env_var "$OUTPUT_FILE" additional_permissions)" \
  "the fix-ci preset can read CI results"

echo
echo "== explain preset =="
run_preset PRESET=explain
assert_status 0 "$STATUS" "succeeds"
assert_contains "$(print_env_var "$OUTPUT_FILE" prompt)" "Explain the changes" \
  "the explain prompt is applied"
assert_eq "" "$(print_env_var "$OUTPUT_FILE" additional_permissions)" \
  "the explain preset needs no extra permissions"

echo
echo "== an explicit input overrides the preset =="
run_preset PRESET=review PRESET_PROMPT="Only look at the migration"
assert_contains "$(print_env_var "$OUTPUT_FILE" prompt)" "Only look at the migration" \
  "an explicit prompt wins"
assert_not_contains "$(print_env_var "$OUTPUT_FILE" prompt)" "Review this pull request" \
  "the preset prompt is not merged in"

run_preset PRESET=review PRESET_ADDITIONAL_PERMISSIONS="issues: write"
assert_eq "issues: write" "$(print_env_var "$OUTPUT_FILE" additional_permissions)" \
  "an explicit permission wins over the preset"

echo
echo "== unknown preset is rejected =="
run_preset PRESET=typo
assert_status 1 "$STATUS" "fails on an unknown preset"
assert_contains "$OUT" "unknown preset 'typo'" "names the offending preset"
assert_contains "$OUT" "default, review, fix-ci, explain" "lists the valid presets"
assert_eq "" "$(print_env_var "$OUTPUT_FILE" prompt)" "nothing is written when resolution fails"

echo
echo "== multi-line values survive the output file =="
run_preset PRESET_PROMPT="first line
second line"
assert_status 0 "$STATUS" "succeeds with a multi-line prompt"
assert_eq "first line
second line" "$(print_env_var "$OUTPUT_FILE" prompt)" "newlines are preserved"

echo
echo "== all three outputs are always written =="
run_preset PRESET=explain
assert_eq "additional_permissions
claude_args
prompt" "$(env_var_names "$OUTPUT_FILE" | sort)" \
  "exactly the three documented outputs are emitted"

summary "test-presets"
