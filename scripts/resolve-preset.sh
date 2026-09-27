#!/usr/bin/env bash
#
# Resolve a task preset into the inputs the wrapped action receives.
#
# A preset is one config that selects a kind of task. It supplies the prompt,
# CLI arguments, and permissions that task normally needs, so a workflow can
# say `preset: review` instead of restating a block of YAML.
#
# A preset only fills inputs the caller left empty, so anything set explicitly
# always wins. That keeps a preset a set of defaults rather than an override.
#
# Required environment:
#   GITHUB_OUTPUT       path to the step output file
#   PRESET              preset name; empty selects the pass-through default
#
# Optional environment (the caller's explicit values):
#   PRESET_PROMPT, PRESET_CLAUDE_ARGS, PRESET_ADDITIONAL_PERMISSIONS

set -euo pipefail

readonly SCRIPT_NAME="resolve-preset"

# The pass-through preset: forward the caller's values untouched.
readonly DEFAULT_PROMPT=""
readonly DEFAULT_CLAUDE_ARGS=""
readonly DEFAULT_PERMISSIONS=""

readonly REVIEW_PROMPT='Review this pull request for correctness, security, and regressions.

Focus on:
- Logic errors and unhandled edge cases
- Security issues, especially input handling and secret exposure
- Missing or misleading tests

Report findings as inline review comments on the lines they apply to. Do not modify any files.'

readonly REVIEW_CLAUDE_ARGS='--max-turns 15'

readonly REVIEW_PERMISSIONS='actions: read'

readonly FIX_CI_PROMPT='Fix the failing CI checks on this pull request.

Use `gh run list` and `gh run view` to find the failing runs, read the logs, and
fix the underlying cause. Re-run the failing checks once a fix is in place. If a
failure is unrelated to this branch, say so instead of changing unrelated code.'

readonly FIX_CI_CLAUDE_ARGS='--max-turns 30'

readonly FIX_CI_PERMISSIONS='actions: read'

readonly EXPLAIN_PROMPT='Explain the changes in this pull request.

Cover what changed and why, then call out anything a reviewer should look at
closely. Do not modify any files.'

readonly EXPLAIN_CLAUDE_ARGS='--max-turns 10'

readonly EXPLAIN_PERMISSIONS=''

log() {
  printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2
}

die() {
  printf '%s: error: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}

# Write a multi-line output using the heredoc form, which is the only form that
# survives embedded newlines.
write_output() {
  local name="$1"
  local value="$2"

  case "$value" in
    *"PRESET_EOF"*)
      die "$name must not contain the literal string PRESET_EOF"
      ;;
  esac

  {
    printf '%s<<PRESET_EOF\n' "$name"
    printf '%s\n' "$value"
    printf 'PRESET_EOF\n'
  } >>"$GITHUB_OUTPUT"
}

# Resolve a preset to the triple of defaults it supplies.
# Sets PRESET_RESOLVED_PROMPT, PRESET_RESOLVED_ARGS, PRESET_RESOLVED_PERMS.
resolve() {
  case "$1" in
    "" | default)
      PRESET_RESOLVED_PROMPT="$DEFAULT_PROMPT"
      PRESET_RESOLVED_ARGS="$DEFAULT_CLAUDE_ARGS"
      PRESET_RESOLVED_PERMS="$DEFAULT_PERMISSIONS"
      ;;
    review)
      PRESET_RESOLVED_PROMPT="$REVIEW_PROMPT"
      PRESET_RESOLVED_ARGS="$REVIEW_CLAUDE_ARGS"
      PRESET_RESOLVED_PERMS="$REVIEW_PERMISSIONS"
      ;;
    fix-ci)
      PRESET_RESOLVED_PROMPT="$FIX_CI_PROMPT"
      PRESET_RESOLVED_ARGS="$FIX_CI_CLAUDE_ARGS"
      PRESET_RESOLVED_PERMS="$FIX_CI_PERMISSIONS"
      ;;
    explain)
      PRESET_RESOLVED_PROMPT="$EXPLAIN_PROMPT"
      PRESET_RESOLVED_ARGS="$EXPLAIN_CLAUDE_ARGS"
      PRESET_RESOLVED_PERMS="$EXPLAIN_PERMISSIONS"
      ;;
    *)
      die "unknown preset '$1' (expected one of: default, review, fix-ci, explain)"
      ;;
  esac
}

main() {
  if [ -z "${GITHUB_OUTPUT-}" ]; then
    die "GITHUB_OUTPUT must not be empty"
  fi

  local preset="${PRESET-}"
  resolve "$preset"

  # An explicit value from the caller always wins over the preset default.
  local prompt="${PRESET_PROMPT-}"
  [ -n "$prompt" ] || prompt="$PRESET_RESOLVED_PROMPT"

  local args="${PRESET_CLAUDE_ARGS-}"
  [ -n "$args" ] || args="$PRESET_RESOLVED_ARGS"

  local permissions="${PRESET_ADDITIONAL_PERMISSIONS-}"
  [ -n "$permissions" ] || permissions="$PRESET_RESOLVED_PERMS"

  write_output "prompt" "$prompt"
  write_output "claude_args" "$args"
  write_output "additional_permissions" "$permissions"

  if [ -n "$preset" ] && [ "$preset" != "default" ]; then
    log "resolved preset '$preset'"
  fi
}

main "$@"
