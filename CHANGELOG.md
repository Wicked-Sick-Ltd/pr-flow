# Changelog

## Unreleased

### Fixed

- `pr-wait.sh` same-name checks are no longer folded by check suite (release 1.1.3). Two jobs in one workflow run share a suite, and an explicit `name:` gives them the same check name, so a passing sibling was hiding a failing job. An Actions `/job/<id>` is one execution, not a stable job id. The helper reads `run_attempt` and `labels` from the Actions jobs API, and only for this repository's `github.com/.../actions/runs/<run>/job/<id>` URL. An older attempt is dropped only when every attempt has exactly one run of that name and those labels and the newest attempt passed. Owner and repository in that URL are compared case-insensitively. If any run of that name has no confirmed attempt, none of them are folded. Jobs whose name appears once are not looked up. Two jobs in the same attempt, a different host, or a partial lookup all stay separate check runs. The 1.1.2 settle window, `|| exit 3`, and `stable_since` behaviour are unchanged.

- `pr-wait.sh` reviewer findings from the 1.1.1 rollout (release 1.1.2):
  - A `--timeout` that fires inside the settle window still prints the digest but exits 2 (1 if a check failed), never 0. A reviewer bot or `needs:` job can still register in that window.
  - Every `$(gh_try ...)`, `$(gh_try_poll ...)` and `$(cursor_or_die ...)` is followed by `|| exit 3`. The script runs without `set -e`, so a `die` inside command substitution only ended the subshell; the script then parsed empty output (for example "rate limit response missing remaining", or re-requesting page 1 until the 50-page cap).
  - After a head mismatch with every listed check complete, the status line says it is waiting for checks on the head instead of printing a settle count from an unset clock.
  - Same-name check runs are folded only within one check suite (a rerun is a new run in the same suite), and only when the newest run passed. Runs in different suites, or with no suite id, are never folded, so a later success cannot mask an earlier failure even when the workflow id matches.
  - When the head moves while paging, the retry waits one poll interval and honours `--timeout`; `--no-wait` gives up after three attempts with exit 2.
  - Offline tests cover each of these, plus a tolerated Bugbot `FORBIDDEN` and an unrelated `FORBIDDEN` on a later page.

- `pr-wait.sh` no longer selects `path` on the GraphQL `Workflow` type. GitHub removed that field, and the poll failed with `Field 'path' doesn't exist on type 'Workflow'`. The query selects `resourcePath` (the equivalent of `path: resourcePath`) and check identity is still the workflow database id, else that resource path, else the app id or slug. The workflow display name stays the fallback when those are missing.
- `pr-wait.sh` keeps polling when the check-suite app lookup returns only the cursor organization's IP allow list `FORBIDDEN` (`type` `FORBIDDEN`, path ending in `checkSuite` / `app`, `extensions.ip_allow_list_failure`). That error is an unknown app. `gh` exits 1 for it. Any other GraphQL error still fails the poll.
- `pr-wait.sh` does not let a later success hide a failure when two checks share a name and have no workflow or app identity. An empty group is not treated as one check. When the app lookup is blocked, a missing workflow or app is not one shared check.

### Added

- `merge-attribution` and `tests-ci-only-self-merge` skills. Every agent merge leaves a PR comment naming the agent and rule plus a daily merge-log line. Tests/CI-only self-merge is a narrow standing permission that applies only where the owner recorded it, and never overrides the `landing-prs` authorization rule or gates (Critical-tier repositories stay excluded; drafts, fresh digest and no `--admin` still apply). `landing-prs` step 5 points to both. Approved by the owner on 19 Nov 2026. Plugin release remains 1.1.0.
- Cursor Cloud Agent setup: `.cursor/install.sh`, `.cursor/environment.json`, and a README section. The install is idempotent, warns when `GH_TOKEN` and `GITHUB_TOKEN` are both unset, and does not call GitHub. The plugin release remains 1.1.0.
- Marketplace-facing README, CONTRIBUTING.md, SECURITY.md, and a GitHub Actions run of `skills/landing-prs/pr-wait_test.sh`. Docs and repository hygiene only. The plugin release remains 1.1.0.

### Changed

- Docs tell readers to fetch `pr-wait.sh` from `Wicked-Sick-Ltd/pr-flow` at `skills/landing-prs/pr-wait.sh`. The old `Wicked-Sick-Ltd/ai-grok-repo` path `plugins/pr-flow/skills/landing-prs/pr-wait.sh` returns 404. Agents run the `pr-wait.sh` beside the loaded skill. A machine that does not already have the skill fetches one pinned revision: `ref="<commit-or-tag>"` `want="<blob sha of pr-wait.sh at that ref>"` `dest="$(mktemp)"` `meta="$(mktemp)"` `(set -o pipefail; gh api --method GET -f ref="$ref" repos/Wicked-Sick-Ltd/pr-flow/contents/skills/landing-prs/pr-wait.sh > "$meta") && test "$(jq -r .sha < "$meta")" = "$want" && jq -r .content < "$meta" | base64 -d > "$dest" && chmod +x "$dest"`. The old `Wicked-Sick-Ltd/ai-grok-repo` path returns 404. `mktemp` avoids the fixed path `/tmp/pr-wait.sh`. `pipefail` keeps a failed download from writing an empty executable. The sha check refuses a blob that is not `want`.
- Plugin manifests are 1.1.1 (`plugin.json`, `.cursor-plugin`, `.claude-plugin`, `.codex-plugin`). The helper agents execute changed, so the package version moves with that helper.
- `landing-prs` and `pr` merge only when the installing user has explicitly asked, or has recorded standing permission that covers the change. Installing the plugin is not permission to merge, and neither is a repository label. Unknown merge state, or a sensitive change the request does not cover, does not merge. Finished work is still ready for review, and `--admin` is still refused. The plugin release remains 1.1.0.
- SECURITY.md no longer describes repository visibility. Email remains the report channel. GitHub's vulnerability form is described as available only after the repository is public and a maintainer has enabled it.
- Current docs name this repository as the vendor source for marketplace copies.

## 1.1.0 (2026-11-05)

### Fixed

- `pr-wait.sh` pages check, review, thread, thread-reply and comment connections and refuses a partial digest. Pages are joined from files so a large page cannot be dropped by the argument-size limit. Pass/fail ignores a concurrency-cancelled run only when a later run of that same check passed. The check identity is the workflow database id, else its path, else the app id or slug; the workflow display name is only a fallback. A commit status is counted on its own, even when its name matches a check run. Stale and any other completed conclusion besides success, neutral and skipped are failures. A timeout during the settle window still prints the digest when every listed check is already complete. `--no-wait` prints the digest and exits 2 while any check is still pending. If the pull request head is not the commit the checks were read from, the digest exits 2 and `head=` stays that checked commit. With no PR argument it passes the current branch to `gh pr view`. The SUMMARY includes `head=`.
- `pr` and `landing-prs`: every helper and `gh` command carries the selected PR and `--repo`. After `gh pr ready`, wait again. Merge passes `--match-head-commit` from that digest and waits again if the head moved.

### Changed

- This repository is the canonical MIT home of PR Flow. Marketplace copies and `ai-*-repo` checkouts should vendor or sync from here.
- License is MIT, copyright Wicked Sick Ltd. Plugin manifests name this repository.
- `landing-prs`: when an agent finishes, the pull request must be ready for review. Draft is only for work in progress. Critical-tier and sensitive changes may start as draft and flip to ready when the agent finishes.
- Skill text points at your organisation's shipping and repository standards. It no longer names one internal conventions document.

## 1.0.0 (2026-10-31)

### Added

- `landing-prs`, `pr`, and `pr-wait.sh`, with Cursor, Claude, Codex and portable plugin manifests.
- Review comments from Claude, Bugbot, Copilot, CodeQL and Semgrep all count. Every finding is fixed or answered, and every thread is resolved, before the PR counts as done.
