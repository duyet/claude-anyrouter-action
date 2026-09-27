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
assert_eq "3" "$(eval_yaml 'len(doc["runs"]["steps"])')" "action has exactly 3 steps"
assert_eq "Configure AnyRouter" "$(eval_yaml 'doc["runs"]["steps"][0]["name"]')" "step 1 is Configure AnyRouter"
assert_eq "Resolve task preset" "$(eval_yaml 'doc["runs"]["steps"][1]["name"]')" "step 2 resolves the preset"
assert_eq "Run Claude Code" "$(eval_yaml 'doc["runs"]["steps"][2]["name"]')" "step 3 is Run Claude Code"

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
for var in ANYROUTER_API_KEY ANYROUTER_BASE_URL ANYROUTER_MODEL ANYROUTER_REPO_URL; do
  assert_contains "$STEP1_ENV" "$var" "step 1 passes $var to the script"
done
assert_eq "4" "$(eval_yaml 'len(doc["runs"]["steps"][0]["env"])')" "step 1 forwards exactly 4 variables"

# The repo URL comes from the event context, so a downstream workflow never
# has to set the attribution itself.
assert_eq '${{ github.server_url }}/${{ github.repository }}' \
  "$(eval_yaml 'doc["runs"]["steps"][0]["env"]["ANYROUTER_REPO_URL"]')" \
  "the repo URL is derived from the GitHub context"

echo
echo "== step 2: Resolve task preset =="
assert_contains "$(eval_yaml 'doc["runs"]["steps"][1]["run"]')" "scripts/resolve-preset.sh" \
  "step 2 delegates to the preset script"
assert_eq "preset" "$(eval_yaml 'doc["runs"]["steps"][1]["id"]')" "step 2 has id 'preset' for output wiring"
for var in PRESET PRESET_PROMPT PRESET_CLAUDE_ARGS PRESET_ADDITIONAL_PERMISSIONS; do
  assert_contains "$(eval_yaml '" ".join(sorted(doc["runs"]["steps"][1]["env"]))')" "$var" \
    "step 2 passes $var to the script"
done

echo
echo "== step 3: Run Claude Code =="
assert_eq "anthropics/claude-code-action@$PINNED_SHA" \
  "$(eval_yaml 'doc["runs"]["steps"][2]["uses"].split("#")[0].strip()')" \
  "step 3 uses the wrapped action pinned to an immutable commit"
assert_eq "claude" "$(eval_yaml 'doc["runs"]["steps"][2]["id"]')" "step 3 has id 'claude' for output wiring"

for passthrough in claude_code_oauth_token bot_id bot_name plugins plugin_marketplaces show_full_output assignee_trigger settings; do
  assert_eq '${{ inputs.'"$passthrough"' }}' \
    "$(eval_yaml 'doc["runs"]["steps"][2]["with"]["'"$passthrough"'"]')" \
    "step 3 forwards $passthrough"
done

# These three come from the preset step, not straight from the caller's inputs,
# so a preset can supply them.
for preset_driven in prompt claude_args additional_permissions; do
  assert_eq '${{ steps.preset.outputs.'"$preset_driven"' }}' \
    "$(eval_yaml 'doc["runs"]["steps"][2]["with"]["'"$preset_driven"'"]')" \
    "step 3 takes $preset_driven from the resolved preset"
done

# The wrapped action's auth check (base-action/src/validate-env.ts) accepts
# ANTHROPIC_API_KEY, CLAUDE_CODE_OAUTH_TOKEN, or workload identity. It does not
# accept ANTHROPIC_AUTH_TOKEN, which is what the gateway really uses, so the key
# also has to reach the wrapped action as `anthropic_api_key` or every run dies
# with "Environment variable validation failed".
assert_eq "\${{ inputs.use_oauth != 'true' && inputs.anyrouter_api_key || '' }}" \
  "$(eval_yaml 'doc["runs"]["steps"][2]["with"]["anthropic_api_key"]')" \
  "step 3 forwards the key so the wrapped action can authenticate"

# The wrapped action's own `model` input is deprecated and no longer read at the
# pinned commit (src/entrypoints/run.ts reads ANTHROPIC_MODEL instead), so
# forwarding it would be a silent no-op.
assert_eq "None" \
  "$(eval_yaml 'doc["runs"]["steps"][2]["with"].get("model")')" \
  "step 3 does not forward the deprecated model input"

echo
echo "== inputs =="
assert_eq "True" "$(eval_yaml 'doc["inputs"]["anyrouter_api_key"]["required"]')" "anyrouter_api_key is required"
assert_eq "https://anyrouter.dev/api/v1" \
  "$(eval_yaml 'doc["inputs"]["anyrouter_base_url"]["default"]')" "anyrouter_base_url default"
assert_eq "anyrouter/auto" \
  "$(eval_yaml 'doc["inputs"]["model"]["default"]')" "model default"
assert_eq "false" \
  "$(eval_yaml 'doc["inputs"]["use_oauth"]["default"]')" "use_oauth default"
assert_eq "default" \
  "$(eval_yaml 'doc["inputs"]["preset"]["default"]')" "preset defaults to the pass-through"

for optional in use_oauth claude_code_oauth_token prompt claude_args additional_permissions preset bot_id bot_name plugins plugin_marketplaces show_full_output assignee_trigger settings; do
  assert_eq "False" \
    "$(eval_yaml 'doc["inputs"]["'"$optional"'"].get("required", False)')" \
    "$optional is optional"
done

assert_eq "16" "$(eval_yaml 'len(doc["inputs"])')" "action declares exactly 16 inputs"

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

for file in README.md LICENSE CHANGELOG.md .gitignore \
  examples/example-interactive.yml examples/example-review.yml \
  examples/example-preset-review.yml examples/example-preset-fix-ci.yml; do
  if [ -s "$REPO_ROOT/$file" ]; then
    _pass "$file exists and is non-empty"
  else
    _fail "$file exists and is non-empty" "missing or empty"
  fi
done

echo
echo "== preset script and tests =="
if [ -x "$REPO_ROOT/scripts/resolve-preset.sh" ]; then
  _pass "scripts/resolve-preset.sh is executable"
else
  _fail "scripts/resolve-preset.sh is executable" "not executable, or missing"
fi

if bash -n "$REPO_ROOT/scripts/resolve-preset.sh" 2>/dev/null; then
  _pass "scripts/resolve-preset.sh parses"
else
  _fail "scripts/resolve-preset.sh parses" "$(bash -n "$REPO_ROOT/scripts/resolve-preset.sh" 2>&1)"
fi

# The documented preset names must match what the script accepts, or the README
# promises a preset that fails at runtime. Checked by running the script rather
# than by matching its case labels, which is the authoritative answer.
DOC_PRESET_OUT="$(mktemp)"
if PRESET="" GITHUB_OUTPUT="$DOC_PRESET_OUT" \
  bash "$REPO_ROOT/scripts/resolve-preset.sh" >/dev/null 2>&1; then
  _pass "the default preset resolves"
else
  _fail "the default preset resolves" "script exited non-zero"
fi
rm -f "$DOC_PRESET_OUT"

for name in default review fix-ci explain; do
  if grep -qE "^\| \`$name\` \|" "$REPO_ROOT/README.md"; then
    DOC_OUT="$(mktemp)"
    if PRESET="$name" GITHUB_OUTPUT="$DOC_OUT" \
      bash "$REPO_ROOT/scripts/resolve-preset.sh" >/dev/null 2>&1; then
      _pass "the documented '$name' preset resolves"
    else
      _fail "the documented '$name' preset resolves" "documented in README but rejected by the script"
    fi
    rm -f "$DOC_OUT"
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
  # Attribution is derived inside the action, so a downstream workflow must not
  # be setting it.
  assert_not_contains "$(cat "$SELF_WORKFLOW")" "app_attribution" \
    "the self-workflow does not set attribution itself"
  # Every job here calls the wrapped action, which exchanges an OIDC token for a
  # GitHub App token. A job that forgets `id-token: write` fails at runtime with
  # an error that reads like a credential problem, not a permissions one.
  SELF_JOBS=$(python3 -c "
import yaml
d=yaml.safe_load(open('$SELF_WORKFLOW'))
for name,job in d['jobs'].items():
    print(f\"{name}={'write' if (job.get('permissions') or {}).get('id-token')=='write' else 'MISSING'}\")
")
  while IFS='=' read -r job state; do
    [ -n "$job" ] || continue
    if [ "$state" = "write" ]; then
      _pass "self-workflow job '$job' grants id-token: write"
    else
      _fail "self-workflow job '$job' grants id-token: write" "the action cannot run without it"
    fi
  done <<< "$SELF_JOBS"

  # An example that omits it ships a workflow that cannot run.
  for example in "$REPO_ROOT"/examples/*.yml; do
    if python3 -c "
import sys,yaml
d=yaml.safe_load(open(sys.argv[1]))
jobs=d.get('jobs') or {}
sys.exit(0 if jobs and all((j.get('permissions') or {}).get('id-token')=='write' for j in jobs.values()) else 1)
" "$example"; then
      _pass "$(basename "$example") grants id-token: write"
    else
      _fail "$(basename "$example") grants id-token: write" "the example cannot run without it"
    fi
  done
else
  _fail ".github/workflows/claude.yml exists" "missing or empty"
fi

echo
echo "== release automation =="
RP_CONFIG="$REPO_ROOT/.github/release-please-config.json"
RP_MANIFEST="$REPO_ROOT/.github/.release-please-manifest.json"
RP_WORKFLOW="$REPO_ROOT/.github/workflows/release-please.yml"

for file in "$RP_CONFIG" "$RP_MANIFEST" "$RP_WORKFLOW"; do
  if [ -s "$file" ]; then
    _pass "$(basename "$file") exists and is non-empty"
  else
    _fail "$(basename "$file") exists and is non-empty" "missing or empty"
  fi
done

if [ -s "$RP_CONFIG" ] && [ -s "$RP_MANIFEST" ]; then
  if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$RP_CONFIG" 2>/dev/null &&
    python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$RP_MANIFEST" 2>/dev/null; then
    _pass "release-please config and manifest are valid JSON"
  else
    _fail "release-please config and manifest are valid JSON" "malformed JSON"
  fi

  # A version disagreement between the two files produces a wrong tag.
  assert_eq "$(python3 -c "import json;print(json.load(open('$RP_CONFIG'))['packages']['.']['changelog-path'])")" \
    "CHANGELOG.md" "config points at the changelog this repo has"
  # The manifest records the version already released, so it has to track the
  # changelog rather than sit at a fixed number: release-please bumps both files
  # together, and a manifest behind the changelog makes it re-tag a release that
  # already shipped.
  if python3 -c "
import json,re,sys
manifest=json.load(open('$RP_MANIFEST'))['.']
if not re.fullmatch(r'\d+\.\d+\.\d+', manifest):
    print('not a release version: '+manifest); sys.exit(1)
text=open('$REPO_ROOT/CHANGELOG.md',encoding='utf-8').read()
m=re.search(r'^##\s+\[?(\d+\.\d+\.\d+)', text, re.M)
if not m:
    print('no released version heading in CHANGELOG.md'); sys.exit(1)
if m.group(1) != manifest:
    print('manifest is '+manifest+', CHANGELOG.md latest is '+m.group(1)); sys.exit(1)
" 2>/dev/null; then
    _pass "manifest tracks the latest released version"
  else
    _fail "manifest tracks the latest released version" \
      "manifest must match the newest version heading in CHANGELOG.md"
  fi

  if python3 -c "
import json,sys
sections=json.load(open('$RP_CONFIG'))['packages']['.']['changelog-sections']
types={s['type'] for s in sections}
missing={'feat','fix','refactor'}-types
sys.exit(1 if missing else 0)
" 2>/dev/null; then
    _pass "changelog sections cover the conventional types used here"
  else
    _fail "changelog sections cover the conventional types used here" "missing a type"
  fi
fi

if [ -s "$RP_WORKFLOW" ]; then
  # release-please needs to write, and a floating action ref would not hold.
  assert_contains "$(cat "$RP_WORKFLOW")" "contents: write" "release-please has contents: write"
  assert_contains "$(cat "$RP_WORKFLOW")" "pull-requests: write" "release-please has pull-requests: write"
  assert_contains "$(cat "$RP_WORKFLOW")" "release-please-action@45996ed1f6d02564a971a2fa1b5860e934307cf7" \
    "release-please is pinned to an immutable commit"
  assert_contains "$(cat "$RP_WORKFLOW")" "config-file: .github/release-please-config.json" \
    "the workflow points at the committed config"
fi

summary "test-action-validation"
