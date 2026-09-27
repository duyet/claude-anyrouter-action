#!/usr/bin/env bash
#
# Configure AnyRouter for the Claude Code CLI.
#
# Writes the ANTHROPIC_* variables that route Claude Code through the AnyRouter
# gateway to the job's environment file ($GITHUB_ENV), so they are visible to
# every subsequent step -- including the composite step of the wrapped
# anthropics/claude-code-action.
#
# The wrapped action reads ANTHROPIC_BASE_URL and the ANTHROPIC_DEFAULT_*_MODEL
# variables from the `env` context of its own run step, and lets ANTHROPIC_MODEL
# and ANTHROPIC_AUTH_TOKEN through the process environment. Populating
# $GITHUB_ENV in a prior step therefore covers both paths.
#
# Required environment:
#   ANYROUTER_API_KEY     gateway credential, forwarded as ANTHROPIC_AUTH_TOKEN
#   ANYROUTER_BASE_URL    Anthropic-compatible base URL
#   ANYROUTER_MODEL       model id, may be empty to leave Claude Code's default
#   GITHUB_ENV            path to the job environment file
#
# Optional environment:
#   ANTHROPIC_CUSTOM_HEADERS    pre-existing headers, merged rather than replaced
#
# App attribution is not configurable: this script always attributes traffic to
# GitHub Actions, so every caller of the action is attributed the same way.

set -euo pipefail

readonly SCRIPT_NAME="configure-anyrouter"

# AnyRouter keys an app on the HTTP-Referer header, reduced to scheme + host +
# port with the path discarded. Every github.com URL therefore collapses to one
# shared `https://github.com` record, so the title is what actually
# distinguishes GitHub Actions traffic from other GitHub-attributed callers.
readonly ATTRIBUTION_URL="https://github.com/features/actions"
readonly ATTRIBUTION_TITLE="GitHub Actions"
readonly MANAGED_HEADER="HTTP-Referer"

log() {
  printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2
}

die() {
  printf '%s: error: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}

# Validate and normalize a required input.
require() {
  local name="$1"
  local value="${2-}"

  if [ -z "$value" ]; then
    die "$name must not be empty"
  fi
}

# Write `name=value` to the job environment file.
# Values containing newlines would terminate the variable early, so reject them.
export_var() {
  local name="$1"
  local value="$2"

  case "$value" in
    *$'\n'* | *$'\r'*)
      die "$name must not contain newlines"
      ;;
  esac

  printf '%s=%s\n' "$name" "$value" >>"$GITHUB_ENV"
}

# Write a multi-line value using the heredoc form of the environment file.
# `EOF` is chosen because it cannot appear in a valid HTTP header value.
export_multiline_var() {
  local name="$1"
  local value="$2"

  case "$value" in
    *"EOF"*)
      die "$name must not contain the literal string EOF"
      ;;
  esac

  {
    printf '%s<<EOF\n' "$name"
    printf '%s\n' "$value"
    printf 'EOF\n'
  } >>"$GITHUB_ENV"
}

main() {
  require "ANYROUTER_API_KEY" "${ANYROUTER_API_KEY-}"
  require "ANYROUTER_BASE_URL" "${ANYROUTER_BASE_URL-}"
  require "GITHUB_ENV" "${GITHUB_ENV-}"

  # The gateway credential becomes ANTHROPIC_AUTH_TOKEN, which Claude Code sends
  # as `Authorization: Bearer <token>`. ANTHROPIC_API_KEY would be sent as
  # `x-api-key` instead, which the gateway rejects.
  # Mask explicitly: a key passed in as a plain action input (rather than a
  # secret expression) is not auto-masked by the runner.
  printf '::add-mask::%s\n' "$ANYROUTER_API_KEY"

  local model="${ANYROUTER_MODEL-}"

  export_var "ANTHROPIC_BASE_URL" "$ANYROUTER_BASE_URL"
  export_var "ANTHROPIC_AUTH_TOKEN" "$ANYROUTER_API_KEY"

  # ANTHROPIC_MODEL is the only model variable the wrapped action consumes
  # directly. Its own `model` input is deprecated and no longer read.
  if [ -n "$model" ]; then
    export_var "ANTHROPIC_MODEL" "$model"
  fi

  # Map Claude Code's three built-in model aliases onto the gateway. Without
  # these the CLI would request `claude-sonnet-*`-style ids that the gateway
  # cannot resolve, which breaks subagents and the /model picker.
  if [ -n "$model" ]; then
    export_var "ANTHROPIC_DEFAULT_SONNET_MODEL" "$model"
    export_var "ANTHROPIC_DEFAULT_OPUS_MODEL" "$model"
    export_var "ANTHROPIC_DEFAULT_HAIKU_MODEL" "$model"
  fi

  # Attribute this traffic to GitHub Actions in AnyRouter's public rankings.
  # Claude Code forwards ANTHROPIC_CUSTOM_HEADERS verbatim, so the attribution
  # headers are merged with any the workflow already declared.
  #
  # The managed header is stripped first: sending HTTP-Referer twice would be an
  # invalid request, and the action's value is the authoritative one.
  local attribution="${MANAGED_HEADER}: ${ATTRIBUTION_URL}"$'\n'"X-AnyRouter-Title: ${ATTRIBUTION_TITLE}"
  local carried="${ANTHROPIC_CUSTOM_HEADERS-}"

  if [ -n "$carried" ]; then
    local filtered
    filtered="$(printf '%s\n' "$carried" | grep -iv "^[[:space:]]*${MANAGED_HEADER}:" || true)"
    if [ -n "$filtered" ]; then
      export_multiline_var "ANTHROPIC_CUSTOM_HEADERS" "${filtered}"$'\n'"${attribution}"
    else
      export_multiline_var "ANTHROPIC_CUSTOM_HEADERS" "$attribution"
    fi
  else
    export_multiline_var "ANTHROPIC_CUSTOM_HEADERS" "$attribution"
  fi

  log "AnyRouter configured (base_url=${ANYROUTER_BASE_URL}, model=${model:-<claude-code-default>})"
}

main "$@"
