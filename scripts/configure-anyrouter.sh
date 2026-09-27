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
#   ANYROUTER_REPO_URL    repository URL used as the attribution referer
#
# Optional environment:
#   ANTHROPIC_CUSTOM_HEADERS    pre-existing headers, merged rather than replaced
#
# App attribution is not configurable. The repository URL comes from the GitHub
# context, so a downstream workflow never has to set it; the title is always
# GitHub Actions.

set -euo pipefail

readonly SCRIPT_NAME="configure-anyrouter"

# The repository URL is the referer, and the display name says the traffic came
# from GitHub Actions rather than a person browsing the repo.
readonly ATTRIBUTION_TITLE="GitHub Actions"
readonly MANAGED_HEADER="HTTP-Referer"
# Used only if the event context carries no repository, which should not happen
# on a GitHub-hosted runner.
readonly FALLBACK_URL="https://github.com/features/actions"

# AnyRouter keys an app on the referer reduced to scheme + host + port, with the
# path discarded. A per-repository referer therefore still resolves to the
# shared `https://github.com` record today, and the title is what separates
# Actions traffic from other github.com-attributed callers. Keeping the full
# repository URL in the header means per-repo attribution starts working if
# AnyRouter ever folds the path into the app key, with no change here.
build_attribution_url() {
  local repo_url="${1-}"

  if [ -z "$repo_url" ]; then
    printf '%s' "$FALLBACK_URL"
    return
  fi

  printf '%s' "$repo_url"
}

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

  # Newlines are legitimate here (header lists are multi-line), but a value
  # assembled from untrusted input must not be able to forge a second entry.
  case "$value" in
    *$'\r'*)
      die "$name must not contain carriage returns"
      ;;
  esac

  {
    printf '%s<<EOF\n' "$name"
    printf '%s\n' "$value"
    printf 'EOF\n'
  } >>"$GITHUB_ENV"
}

# Reject values that span lines. Used for inputs that are interpolated into a
# multi-line environment-file entry, where an embedded newline would forge a
# second variable.
require_single_line() {
  local name="$1"
  local value="${2-}"

  case "$value" in
    *$'\n'* | *$'\r'*)
      die "$name must not contain newlines"
      ;;
  esac
}

main() {
  require "ANYROUTER_API_KEY" "${ANYROUTER_API_KEY-}"
  require "ANYROUTER_BASE_URL" "${ANYROUTER_BASE_URL-}"
  require "GITHUB_ENV" "${GITHUB_ENV-}"
  require_single_line "ANYROUTER_REPO_URL" "${ANYROUTER_REPO_URL-}"

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
  local attribution="${MANAGED_HEADER}: $(build_attribution_url "${ANYROUTER_REPO_URL-}")"$'\n'"X-AnyRouter-Title: ${ATTRIBUTION_TITLE}"
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
