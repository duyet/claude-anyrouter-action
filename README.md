# Claude Code (AnyRouter)

A composite GitHub Action that wraps
[`anthropics/claude-code-action`](https://github.com/anthropics/claude-code-action)
and points it at the [AnyRouter](https://anyrouter.dev) gateway.

Pointing Claude Code at a third-party Anthropic-compatible endpoint means
exporting five `ANTHROPIC_*` variables in the right order, using the auth
variable the gateway actually accepts, and making sure the values survive the
wrapped action's `env:` block. This action does that in one step so a workflow
is just a checkout plus a `uses:` line.

## Usage

```yaml
name: Claude Code

on:
  issue_comment:
    types: [created]
  pull_request_review:
    types: [submitted]

jobs:
  claude:
    if: contains(github.event.comment.body, '@claude') || contains(github.event.review.body, '@claude')
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: read
      issues: read
    steps:
      - uses: actions/checkout@v5

      - uses: duyet/claude-anyrouter-action@main
        with:
          anyrouter_api_key: ${{ secrets.ANYROUTER_API_KEY }}
```

See [`examples/`](./examples) for interactive and code-review workflows.

## Presets

A preset picks a kind of task with one value, supplying the prompt, CLI
arguments, and permissions that task normally needs:

```yaml
      - uses: duyet/claude-anyrouter-action@main
        with:
          anyrouter_api_key: ${{ secrets.ANYROUTER_API_KEY }}
          preset: review
```

| Preset | Task | Grants |
| --- | --- | --- |
| `default` | Forwards your own inputs. Claude does what the comment asked. | – |
| `review` | Review the pull request for correctness and security, posting inline comments without editing files. | `actions: read` |
| `fix-ci` | Find failing checks, read their logs, and fix the cause. | `actions: read` |
| `explain` | Describe the changes and what a reviewer should look at. | – |

**A preset only fills inputs you left empty.** Anything you set explicitly wins,
so a preset is a set of defaults, not an override:

```yaml
        with:
          anyrouter_api_key: ${{ secrets.ANYROUTER_API_KEY }}
          preset: review
          prompt: 'Only check the migration in src/db.'
```

An unknown preset fails the step with the list of valid names rather than
silently falling back.

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `anyrouter_api_key` | yes | – | AnyRouter API key. Exported as `ANTHROPIC_AUTH_TOKEN`. |
| `anyrouter_base_url` | no | `https://anyrouter.dev/api/v1` | AnyRouter Anthropic-compatible base URL. |
| `model` | no | `anyrouter/auto` | Model id to route to. Empty leaves Claude Code's own default. |
| `use_oauth` | no | `false` | Use the official OAuth token instead of AnyRouter. |
| `claude_code_oauth_token` | no | `""` | OAuth token. Only used when `use_oauth` is `true`. |
| `prompt` | no | `""` | Instructions. Empty uses the comment that tagged Claude. |
| `claude_args` | no | `""` | Extra [Claude Code CLI arguments](https://code.claude.com/docs/en/cli-reference). |
| `additional_permissions` | no | `""` | Extra GitHub permissions, e.g. `actions: read`. |
| `preset` | no | `default` | Task preset. See [Presets](#presets). |
| `bot_id` | no | `""` | Bot user id for PR review comments. |
| `bot_name` | no | `""` | Bot name for PR review comments. |
| `plugins` | no | `""` | Newline-separated Claude Code plugins to install. |
| `plugin_marketplaces` | no | `""` | Newline-separated plugin marketplace Git URLs. |
| `show_full_output` | no | `false` | Full JSON output in logs. **May expose secrets.** |
| `assignee_trigger` | no | `""` | Assignee login that triggers the issue-plan flow. |
| `settings` | no | `""` | Claude Code settings as JSON or a path to a settings file. |

The last eight are forwarded verbatim to the wrapped action, so a workflow can
point at this action without knowing which action is underneath. `prompt`,
`claude_args`, and `additional_permissions` are routed through the preset step
first, so a preset can supply them when you have not.

## Outputs

`conclusion`, `execution_file`, `branch_name`, `github_token`,
`structured_output`, and `session_id`, forwarded from the wrapped action.

## What it exports

When `use_oauth` is `false` (the default) the first step appends to
[`$GITHUB_ENV`](https://docs.github.com/en/actions/using-workflows/workflow-commands-for-github-actions#environment-files):

| Variable | Value | Why |
| --- | --- | --- |
| `ANTHROPIC_BASE_URL` | `anyrouter_base_url` | Routes requests to the gateway. |
| `ANTHROPIC_AUTH_TOKEN` | `anyrouter_api_key` | Sent as `Authorization: Bearer`. |
| `ANTHROPIC_MODEL` | `model` | The model Claude Code requests. |
| `ANTHROPIC_DEFAULT_SONNET_MODEL` | `model` | Resolves the `sonnet` alias. |
| `ANTHROPIC_DEFAULT_OPUS_MODEL` | `model` | Resolves the `opus` alias. |
| `ANTHROPIC_DEFAULT_HAIKU_MODEL` | `model` | Resolves the `haiku` alias. |
| `ANTHROPIC_CUSTOM_HEADERS` | `HTTP-Referer` + `X-AnyRouter-Title` | Always. See [Attribution](#attribution). |

A few deliberate details:

- **`ANTHROPIC_AUTH_TOKEN`, not `ANTHROPIC_API_KEY`.** Claude Code sends
  `ANTHROPIC_API_KEY` as an `x-api-key` header. The gateway expects
  `Authorization: Bearer`, so the wrong variable produces a `401` even with a
  valid key.
- **The three `ANTHROPIC_DEFAULT_*_MODEL` aliases.** Without them Claude Code
  requests `claude-sonnet-*` style ids that the gateway cannot resolve, which
  breaks subagents and the `/model` picker even when the main session works.
  Set `model` to a specific id to pin all three, or to `""` to leave every model
  to Claude Code's own default.
- **The key is never logged.** The script registers it with `::add-mask::`
  before use, and no log line echoes it.

## Attribution

Traffic is always attributed to GitHub Actions, with no configuration:

```
HTTP-Referer: https://github.com/features/actions
X-AnyRouter-Title: GitHub Actions
```

AnyRouter keys an app on the referer reduced to scheme, host, and port with the
path discarded, so every GitHub URL collapses to a single shared
`https://github.com` record. The title is therefore what actually separates
GitHub Actions traffic from other callers attributing to a `github.com` URL.

The repository is appended as a `ref` query parameter, derived automatically
from the event context, so you do not configure it:

```
HTTP-Referer: https://github.com/duyet/monorepo
X-AnyRouter-Title: GitHub Actions
```

The referer is the repository the run belongs to, taken from the GitHub
context, so a downstream workflow never has to configure it. The title always
says GitHub Actions.

Note that AnyRouter reduces the referer to scheme, host, and port today, so
every repository still resolves to one shared `https://github.com` record and
the title is what separates this traffic from other github.com-attributed
callers. Sending the full repository URL anyway means per-repository
attribution starts working unchanged if AnyRouter folds the path into the app
key.
[duyet/anyrouter#3648](https://github.com/duyet/anyrouter/issues/3648) tracks
first-class GitHub Actions attribution and per-repository analytics.

These headers are appended to any `ANTHROPIC_CUSTOM_HEADERS` the workflow
already declares, so you can still add `X-AnyRouter-Categories` or
`X-AnyRouter-Source` yourself. A referer the workflow sets is replaced rather
than sent twice, which would be an invalid request.

## Notes and caveats

**`model` beats `--model` in `claude_args`.** At the wrapped commit the model is
resolved as `ANTHROPIC_MODEL || --model from claude_args`, so the `model` input
wins. To choose a model per-run via `claude_args` instead, set `model: ""` and
pass `--model` yourself.

**`anyrouter_api_key` is required even in OAuth mode.** GitHub enforces
`required` regardless of the `use_oauth` value, so an OAuth-only workflow must
still pass a placeholder. Use `use_oauth: true` with a token when you want the
official Anthropic endpoint and Claude Code's default model resolution.

**Supplying both an OAuth token and an API key is ambiguous.** The wrapped
action forwards both to Claude Code. Prefer one.

**The wrapped action is pinned** to commit
`cfc3eb22bfed5c26ef66e3223c982af27e4524de`. Bumping it is a deliberate change
to this repo's tests, which assert the pin.

## Development

```bash
./tests/run-all.sh                  # everything
./tests/test-action-validation.sh   # action.yml structure and the pinned commit
./tests/test-env-mapping.sh         # executes the env script and asserts output
./tests/test-presets.sh             # executes the preset script and asserts output
```

`test-env-mapping.sh` and `test-presets.sh` execute the scripts against a
throwaway output file, so their behaviour is verified by running them rather
than by grepping YAML. All three are dependency-free apart from `python3` (for
YAML and environment-file parsing); `jq` is not required.

Both run in CI on every push and pull request.

## Releases

[Release Please](https://github.com/googleapis/release-please) watches
conventional commits on `main` and maintains a standing release PR that humans
merge. It tags `vX.Y.Z` and updates `CHANGELOG.md`.

Pre-1.0 bump rules: a `feat` bumps the **patch**, and only a breaking change
(`feat!` or a `BREAKING CHANGE` footer) cuts a minor. That keeps a new input or
a behavioural tweak from implying API stability the action does not have yet.

Downstream workflows can pin `duyet/claude-anyrouter-action@v0.1.0` or track
`@main`. Note that the wrapped `anthropics/claude-code-action` is pinned to a
commit inside this action, so a version bump of this action is the way to pick
up an upstream change.

## License

[MIT](./LICENSE)
