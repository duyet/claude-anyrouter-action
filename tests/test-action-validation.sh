#!/usr/bin/env bash
#
# Structural validation of action.yml.
#
# These assertions encode the contract callers depend on: the input names and
# their defaults, the two-step shape, the guard around the AnyRouter step, and
# the pinned commit of the wrapped action. A refactor that changes any of them
# should have to update this file deliberately.

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"

# shellcheck source=helpers.sh
. "$TESTS_DIR/helpers.sh"

ACTION_YML="$REPO_ROOT/action.yml"
SCRIPT="$REPO_ROOT/scripts/configure-anyrouter.sh"

PINNED_SHA="cfc3eb22bfed5c26ef66e3223c982af27e4524de"

# eval_yaml <python-expression> -> prints the result
# Runs a snippet against the parsed action.yml document.
eval_yaml() {
  python3 - "$ACTION_YML" "$1" <<'PY'
import sys
import yaml

doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
print(eval(sys.argv[2]), end="")
PY
}

echo "== action.yml parses =="
if parse_error=$(python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$ACTION_YML" 2>&1); then
  _pass "action.yml is valid YAML"
else
  _fail "action.yml is valid YAML" "$parse_error"
fi

echo
echo "== composite run shape =="
assert_eq "composite" "$(eval_yaml 'doc["runs"]["using"]')" "runs.using is composite"
assert_eq "2" "$(eval_yaml 'len(doc["runs"]["steps"])')" "action has exactly 2 steps"
assert_eq "Configure AnyRouter" "$(eval_yaml 'doc["runs"]["steps"][0]["name"]')" "step 1 is Configure AnyRouter"
assert_eq "Run Claude Code" "$(eval_yaml 'doc["runs"]["steps"][1]["name"]')" "step 2 is Run Claude Code"

echo
echo "== step 1: Configure AnyRouter =="
assert_eq "bash" "$(eval_yaml 'doc["runs"]["steps"][0]["shell"]')" "step 1 declares a shell"
assert_contains \
  "$(eval_yaml 'doc["runs"]["steps"][0]["run"]')" \
  "scripts/configure-anyrouter.sh" \
  "step 1 delegates to the configure script"
assert_eq "inputs.use_oauth != 'true'" \
  "$(eval_yaml 'doc["runs"]["steps"][0]["if"]')" \
  "step 1 is skipped when use_oauth is true"

STEP1_ENV="$(eval_yaml '" ".join(sorted(doc["runs"]["steps"][0]["env"]))')"
for var in ANYROUTER_API_KEY ANYROUTER_BASE_URL ANYROUTER_MODEL ANYROUTER_REPO_REF; do
  assert_contains "$STEP1_ENV" "$var" "step 1 passes $var to the script"
done
assert_eq "4" "$(eval_yaml 'len(doc["runs"]["steps"][0]["env"])')" "step 1 forwards exactly 4 variables"

# The repo ref comes from the event context, so the action derives it rather
# than making each caller repeat it.
assert_eq '${{ github.server_url }}/${{ github.repository }}' \
  "$(eval_yaml 'doc["runs"]["steps"][0]["env"]["ANYROUTER_REPO_REF"]')" \
  "the repo ref is derived from the GitHub context"

echo
echo "== step 2: Run Claude Code =="
assert_eq "anthropics/claude-code-action@$PINNED_SHA" \
  "$(eval_yaml 'doc["runs"]["steps"][1]["uses"].split("#")[0].strip()')" \
  "step 2 uses the wrapped action pinned to an immutable commit"
assert_eq "claude" "$(eval_yaml 'doc["runs"]["steps"][1]["id"]')" "step 2 has id 'claude' for output wiring"

for passthrough in prompt claude_args additional_permissions claude_code_oauth_token bot_id bot_name plugins plugin_marketplaces show_full_output assignee_trigger settings; do
  assert_eq '${{ inputs.'"$passthrough"' }}' \
    "$(eval_yaml 'doc["runs"]["steps"][1]["with"]["'"$passthrough"'"]')" \
    "step 2 forwards $passthrough"
done

# The wrapped action's own `model` input is deprecated and no longer read at the
# pinned commit (src/entrypoints/run.ts reads ANTHROPIC_MODEL instead), so
# forwarding it would be a silent no-op.
assert_eq "None" \
  "$(eval_yaml 'doc["runs"]["steps"][1]["with"].get("model")')" \
  "step 2 does not forward the deprecated model input"

echo
echo "== inputs =="
assert_eq "True" "$(eval_yaml 'doc["inputs"]["anyrouter_api_key"]["required"]')" "anyrouter_api_key is required"
assert_eq "https://anyrouter.dev/api/v1" \
  "$(eval_yaml 'doc["inputs"]["anyrouter_base_url"]["default"]')" "anyrouter_base_url default"
assert_eq "anyrouter/auto" \
  "$(eval_yaml 'doc["inputs"]["model"]["default"]')" "model default"
assert_eq "false" \
  "$(eval_yaml 'doc["inputs"]["use_oauth"]["default"]')" "use_oauth default"

for optional in use_oauth claude_code_oauth_token prompt claude_args additional_permissions bot_id bot_name plugins plugin_marketplaces show_full_output assignee_trigger settings; do
  assert_eq "False" \
    "$(eval_yaml 'doc["inputs"]["'"$optional"'"].get("required", False)')" \
    "$optional is optional"
done

assert_eq "15" "$(eval_yaml 'len(doc["inputs"])')" "action declares exactly 15 inputs"

# Attribution is not configurable: it is always GitHub Actions.
assert_eq "False" "$(eval_yaml '"app_attribution" in doc["inputs"]')" \
  "app_attribution is not an input (attribution is always GitHub Actions)"

echo
echo "== outputs =="
for output in conclusion execution_file branch_name github_token structured_output session_id; do
  assert_eq '${{ steps.claude.outputs.'"$output"' }}' \
    "$(eval_yaml 'doc["outputs"]["'"$output"'"]["value"]')" "output $output is wired to step 2"
done

echo
echo "== repository files =="
if [ -x "$SCRIPT" ]; then
  _pass "scripts/configure-anyrouter.sh is executable"
else
  _fail "scripts/configure-anyrouter.sh is executable" "not executable, or missing"
fi

if bash -n "$SCRIPT" 2>/dev/null; then
  _pass "scripts/configure-anyrouter.sh parses"
else
  _fail "scripts/configure-anyrouter.sh parses" "$(bash -n "$SCRIPT" 2>&1)"
fi

for file in README.md LICENSE .gitignore examples/example-interactive.yml examples/example-review.yml; do
  if [ -s "$REPO_ROOT/$file" ]; then
    _pass "$file exists and is non-empty"
  else
    _fail "$file exists and is non-empty" "missing or empty"
  fi
done

echo
echo "== this repo dogfoods the action =="
SELF_WORKFLOW="$REPO_ROOT/.github/workflows/claude.yml"
if [ -s "$SELF_WORKFLOW" ]; then
  _pass ".github/workflows/claude.yml exists"
  # A drifting self-workflow would silently stop exercising the action.
  assert_contains "$(cat "$SELF_WORKFLOW")" "uses: duyet/claude-anyrouter-action@main" \
    "the self-workflow uses this action"
  assert_contains "$(cat "$SELF_WORKFLOW")" "anyrouter_api_key: \${{ secrets.ANYROUTER_API_KEY }}" \
    "the self-workflow supplies the credential from a secret"
else
  _fail ".github/workflows/claude.yml exists" "missing or empty"
fi

summary "test-action-validation"
