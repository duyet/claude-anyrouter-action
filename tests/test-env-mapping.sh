#!/usr/bin/env bash
#
# Behavioural tests for the AnyRouter -> ANTHROPIC_* environment mapping.
#
# Runs scripts/configure-anyrouter.sh against a throwaway environment file and
# asserts on what it wrote, which is the contract the wrapped
# anthropics/claude-code-action actually consumes.

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"

# shellcheck source=helpers.sh
. "$TESTS_DIR/helpers.sh"

SCRIPT="$REPO_ROOT/scripts/configure-anyrouter.sh"
API_KEY="sk-ar-v1-test-key-do-not-use"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

COUNTER=0

# run_configure [KEY=VALUE ...]
# Sets OUT (combined stdout+stderr) and STATUS (exit code), and points
# ENV_FILE at the environment file the script wrote to.
run_configure() {
  COUNTER=$((COUNTER + 1))
  ENV_FILE="$TMP_ROOT/env.$COUNTER"
  : >"$ENV_FILE"

  OUT="$(env -i \
    PATH="$PATH" \
    GITHUB_ENV="$ENV_FILE" \
    ANYROUTER_API_KEY="$API_KEY" \
    ANYROUTER_BASE_URL="https://anyrouter.dev/api/v1" \
    ANYROUTER_MODEL="anyrouter/auto" \
    "$@" \
    bash "$SCRIPT" 2>&1)"
  STATUS=$?
}

echo "== default configuration =="
run_configure
assert_status 0 "$STATUS" "succeeds"
assert_eq "https://anyrouter.dev/api/v1" "$(print_env_var "$ENV_FILE" ANTHROPIC_BASE_URL)" \
  "ANTHROPIC_BASE_URL is the AnyRouter base URL"
assert_eq "$API_KEY" "$(print_env_var "$ENV_FILE" ANTHROPIC_AUTH_TOKEN)" \
  "ANTHROPIC_API_KEY is exported as ANTHROPIC_AUTH_TOKEN"
assert_eq "anyrouter/auto" "$(print_env_var "$ENV_FILE" ANTHROPIC_MODEL)" \
  "model is exported as ANTHROPIC_MODEL"
assert_eq "anyrouter/auto" "$(print_env_var "$ENV_FILE" ANTHROPIC_DEFAULT_SONNET_MODEL)" \
  "sonnet alias maps to the gateway model"
assert_eq "anyrouter/auto" "$(print_env_var "$ENV_FILE" ANTHROPIC_DEFAULT_OPUS_MODEL)" \
  "opus alias maps to the gateway model"
assert_eq "anyrouter/auto" "$(print_env_var "$ENV_FILE" ANTHROPIC_DEFAULT_HAIKU_MODEL)" \
  "haiku alias maps to the gateway model"

# ANTHROPIC_API_KEY would be sent as `x-api-key`, which the gateway rejects in
# favour of `Authorization: Bearer`.
assert_ne "x" "$(print_env_var "$ENV_FILE" ANTHROPIC_API_KEY)" "ANTHROPIC_API_KEY is not set"

echo
echo "== credential is masked and not logged =="
assert_contains "$OUT" "::add-mask::$API_KEY" "the credential is registered as a log mask"
# The mask directive itself carries the credential by design; what must not leak
# is the credential appearing in ordinary log output.
LOG_WITHOUT_MASKS="$(printf '%s\n' "$OUT" | grep -v '^::add-mask::' || true)"
assert_not_contains "$LOG_WITHOUT_MASKS" "$API_KEY" "the credential is not echoed into the log"
assert_contains "$LOG_WITHOUT_MASKS" "AnyRouter configured" "the script confirms what it configured"

echo
echo "== custom base URL =="
run_configure ANYROUTER_BASE_URL="https://gateway.internal/anthropic"
assert_status 0 "$STATUS" "succeeds with a custom base URL"
assert_eq "https://gateway.internal/anthropic" "$(print_env_var "$ENV_FILE" ANTHROPIC_BASE_URL)" \
  "a custom base URL is honoured"

echo
echo "== empty model leaves Claude Code's default alone =="
run_configure ANYROUTER_MODEL=""
assert_status 0 "$STATUS" "succeeds with an empty model"
assert_eq "" "$(print_env_var "$ENV_FILE" ANTHROPIC_MODEL)" "ANTHROPIC_MODEL is not set"
for alias in ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL; do
  assert_eq "" "$(print_env_var "$ENV_FILE" "$alias")" "$alias is not set"
done
assert_eq "https://anyrouter.dev/api/v1" "$(print_env_var "$ENV_FILE" ANTHROPIC_BASE_URL)" \
  "the gateway is still configured"

echo
echo "== app attribution is always GitHub Actions =="
run_configure
assert_status 0 "$STATUS" "succeeds"
assert_eq "HTTP-Referer: https://github.com/features/actions
X-AnyRouter-Title: GitHub Actions" "$(print_env_var "$ENV_FILE" ANTHROPIC_CUSTOM_HEADERS)" \
  "traffic is attributed to GitHub Actions with no configuration"

# The action sends a fixed referer and title, so these must be present even
# alongside a workflow that sets its own.
run_configure ANYROUTER_MODEL=""
assert_eq "HTTP-Referer: https://github.com/features/actions
X-AnyRouter-Title: GitHub Actions" "$(print_env_var "$ENV_FILE" ANTHROPIC_CUSTOM_HEADERS)" \
  "attribution is emitted independently of the model setting"

echo
echo "== attribution records the originating repository =="
run_configure ANYROUTER_REPO_REF="https://github.com/duyet/monorepo"
assert_status 0 "$STATUS" "succeeds with a repo ref"
assert_eq "HTTP-Referer: https://github.com/features/actions?ref=https://github.com/duyet/monorepo
X-AnyRouter-Title: GitHub Actions" "$(print_env_var "$ENV_FILE" ANTHROPIC_CUSTOM_HEADERS)" \
  "the repo is appended as a ref query parameter"

run_configure ANYROUTER_REPO_REF="https://github.com/acme/api"
assert_contains "$(print_env_var "$ENV_FILE" ANTHROPIC_CUSTOM_HEADERS)" \
  "?ref=https://github.com/acme/api" "a different repo yields a different referer"

# The ref is untrusted input from the event context, so a newline in it would
# let an attacker inject a second variable into the environment file.
run_configure ANYROUTER_REPO_REF="https://github.com/acme/api
ANTHROPIC_API_KEY=injected"
assert_status 1 "$STATUS" "rejects a repo ref containing a newline"
assert_contains "$OUT" "ANYROUTER_REPO_REF must not contain newlines" "reports the newline injection"
assert_eq "" "$(print_env_var "$ENV_FILE" ANTHROPIC_API_KEY)" "no variable is injected by a rejected ref"

echo
echo "== app attribution merges with existing custom headers =="
run_configure ANTHROPIC_CUSTOM_HEADERS="X-AnyRouter-Source: github-actions
X-AnyRouter-Categories: cli-agent"
assert_status 0 "$STATUS" "succeeds when merging custom headers"
assert_eq "X-AnyRouter-Source: github-actions
X-AnyRouter-Categories: cli-agent
HTTP-Referer: https://github.com/features/actions
X-AnyRouter-Title: GitHub Actions" "$(print_env_var "$ENV_FILE" ANTHROPIC_CUSTOM_HEADERS)" \
  "workflow headers are preserved and attribution is appended"

echo
echo "== a workflow-supplied HTTP-Referer does not duplicate =="
run_configure ANTHROPIC_CUSTOM_HEADERS="HTTP-Referer: https://someone-else.example
X-AnyRouter-Source: github-actions"
assert_status 0 "$STATUS" "succeeds when a referer is already set"
assert_eq "X-AnyRouter-Source: github-actions
HTTP-Referer: https://github.com/features/actions
X-AnyRouter-Title: GitHub Actions" "$(print_env_var "$ENV_FILE" ANTHROPIC_CUSTOM_HEADERS)" \
  "the stale referer is replaced rather than sent twice"

run_configure ANTHROPIC_CUSTOM_HEADERS="  http-referer: https://someone-else.example"
assert_eq "HTTP-Referer: https://github.com/features/actions
X-AnyRouter-Title: GitHub Actions" "$(print_env_var "$ENV_FILE" ANTHROPIC_CUSTOM_HEADERS)" \
  "a differently-cased referer is also replaced"

echo
echo "== required input validation =="
run_configure ANYROUTER_API_KEY=""
assert_status 1 "$STATUS" "fails on an empty API key"
assert_contains "$OUT" "ANYROUTER_API_KEY must not be empty" "reports the empty API key"

run_configure ANYROUTER_BASE_URL=""
assert_status 1 "$STATUS" "fails on an empty base URL"
assert_contains "$OUT" "ANYROUTER_BASE_URL must not be empty" "reports the empty base URL"

run_configure ANYROUTER_BASE_URL="https://anyrouter.dev/api/v1
ANTHROPIC_API_KEY=injected"
assert_status 1 "$STATUS" "rejects a base URL containing a newline"
assert_contains "$OUT" "must not contain newlines" "reports the newline injection"
assert_eq "" "$(print_env_var "$ENV_FILE" ANTHROPIC_API_KEY)" "no variable is injected by a rejected input"

echo
echo "== exactly the expected variables are written =="
run_configure
assert_eq "ANTHROPIC_AUTH_TOKEN
ANTHROPIC_BASE_URL
ANTHROPIC_CUSTOM_HEADERS
ANTHROPIC_DEFAULT_HAIKU_MODEL
ANTHROPIC_DEFAULT_OPUS_MODEL
ANTHROPIC_DEFAULT_SONNET_MODEL
ANTHROPIC_MODEL" "$(env_var_names "$ENV_FILE" | sort)" \
  "the environment file contains no unexpected variables"

summary "test-env-mapping"
