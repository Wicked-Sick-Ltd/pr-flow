# PR Flow

Open a GitHub pull request, wait until CI and reviewer bots finish, answer every finding, and merge only when the user has authorized it and the digest is clean.

**PR Flow** is the MIT-licensed agent plugin for that lifecycle, maintained by Wicked Sick Ltd. The rules live in [landing-prs](skills/landing-prs/SKILL.md). The command form is [pr](skills/pr/SKILL.md) (`create`, `watch`, `merge`, `land`, `status`, `sweep`). The wait step is [pr-wait.sh](skills/landing-prs/pr-wait.sh). Merge bookkeeping lives in [merge-attribution](skills/merge-attribution/SKILL.md) (who merged what, under which rule) and [tests-ci-only-self-merge](skills/tests-ci-only-self-merge/SKILL.md) (a narrow standing permission, only where the owner recorded it). Current release: **1.1.4**.

This repository is the source of truth. Marketplace copies, including `Wicked-Sick-Ltd/ai-marketplace`, vendor from here. See [VENDORED.md](VENDORED.md).

## What it does

1. Branch off the default branch and open a pull request against the repository's integration branch.
2. Wait until every check run and commit status on the head commit has finished. Reviewer bots that register a check (Claude, Bugbot, Copilot, CodeQL, Semgrep, and the repository's own workflows) are part of that wait.
3. Fix each failed check and each open review thread, or reply with the reason, then wait again.
4. Merge when the user has authorized it and the digest is clean: `checks_pending=0`, `checks_failed=0`, `unresolved_threads=0`, `truncated=0`, and `head=` is the commit that will merge. Installing the plugin is not that authorization. If the user did not ask to merge, or the change touches auth, payments, migrations, infra, or secrets and the request does not cover that risk, the agent asks instead of merging.

A finished pull request is **ready for review**. Use a draft while work is still in progress. Changes that touch auth, payments, migrations, infra, or secrets may start as a draft and become ready when the agent stops.

## Install for Cursor

The tree is a Cursor plugin (`.cursor-plugin/plugin.json`) and a portable Agent Plugin (`plugin.json` at the root).

**On your machine.** Clone this repository and copy it to `~/.cursor/plugins/local/pr-flow` (the copy must live inside that folder). Reload Cursor, then open **Customize** and confirm `landing-prs` and `pr`. Enterprise admins must allow local plugin imports.

**For a team.** In the Cursor dashboard, open **Plugins & MCPs**, add a team marketplace with **Import from Repo**, and paste:

`https://github.com/Wicked-Sick-Ltd/pr-flow`

Add the `pr-flow` plugin and set who can install it. The Cursor GitHub App needs access to this repository. Turn on **Auto Refresh** so pushes here update the marketplace index.

**Cursor Marketplace.** After this repository is public, submit it at [cursor.com/marketplace/publish](https://cursor.com/marketplace/publish). Listed plugins are open source, and this package is MIT.

Start a new agent session after installing so the skills load.

## Example

Ask the agent:

> Land this. Open the pull request, wait for CI and the reviewer bots, fix what they find, and merge when the digest is clean.

That request is what authorizes the merge. The agent still asks when the change touches auth, payments, migrations, infra, or secrets and this request did not cover that risk.

The agent follows [landing-prs](skills/landing-prs/SKILL.md). To print one digest for pull request 42 without waiting:

```bash
bash skills/landing-prs/pr-wait.sh 42 --repo OWNER/NAME --no-wait
```

Exit 0 means every listed check on that commit passed. Pass the SUMMARY `head=` value to `gh pr merge --match-head-commit`. To print settings with no GitHub call:

```bash
bash skills/landing-prs/pr-wait.sh --dry-run
```

## Who merged what

Every merge an agent makes leaves one comment on the pull request ([merge-attribution](skills/merge-attribution/SKILL.md)). GitHub is the merge log, so nothing else is written down. To list a day's merges across one or more GitHub users or organisations, with the merges that have no attribution comment first:

```bash
bash skills/merge-attribution/merge-audit.sh --owner OWNER --date 2026-11-27
```

Exit 0 means every merge that day carries an attribution comment. Exit 1 means at least one does not. Exit 3 means the list could not be completed. `--dry-run` prints the search with no GitHub call.

## Requirements

- [GitHub CLI](https://cli.github.com/) (`gh`), authenticated for the repositories you land
- Bash
- [`jq`](https://jqlang.org/)

On Windows, use Git Bash or WSL with those tools on `PATH`. Resolve `pr-wait.sh` and `merge-audit.sh` from the installed skill folders (`skills/landing-prs/` and `skills/merge-attribution/` beside this plugin).

## Fetch pr-wait.sh

Fetch the helper from this repository: `Wicked-Sick-Ltd/pr-flow`, path `skills/landing-prs/pr-wait.sh`. The old location `Wicked-Sick-Ltd/ai-grok-repo` `plugins/pr-flow/skills/landing-prs/pr-wait.sh` returns 404.

Run the `pr-wait.sh` that shipped with the skill. Do not replace that copy with a download. A machine that does not already have the skill can fetch one pinned revision. Set `ref` to the commit or tag, and `want` to the blob sha of `pr-wait.sh` at that ref.

```bash
ref="<commit-or-tag>"
want="<blob sha of pr-wait.sh at that ref>"
dest="$(mktemp)"
meta="$(mktemp)"
(set -o pipefail; gh api --method GET -f ref="$ref" repos/Wicked-Sick-Ltd/pr-flow/contents/skills/landing-prs/pr-wait.sh > "$meta") && test "$(jq -r .sha < "$meta")" = "$want" && jq -r .content < "$meta" | base64 -d > "$dest" && chmod +x "$dest"
```

Run `"$dest"`. `--method GET` is required: `gh api` sends a POST when `-f` is present, and the contents API does not return the file for that POST. `mktemp` creates a new private file, so the helper is not written to the fixed path `/tmp/pr-wait.sh`. On a shared machine another user can replace that fixed path before it is executed. `pipefail` makes a failed `gh api` fail the command. Without it, `base64 -d` can succeed on empty input and leave an empty executable. The sha check refuses the file when the blob is not the revision named in `want`.

## Cloud agent environment

Cursor Cloud Agents run `bash .cursor/install.sh` from `.cursor/environment.json`. The script is idempotent and does not call GitHub. It installs `gh`, `jq`, Python 3, and `column` (`bsdextrautils`) for the helper and the regression tests, plus `shellcheck`, `shfmt`, and `bats` for shell checks. When `GH_TOKEN` and `GITHUB_TOKEN` are both unset, it prints a warning that names those variables and still exits 0. The regression tests mock `gh` and stay offline.

## Other agents

Claude, Codex, and Copilot manifests live in `.claude-plugin/`, `.codex-plugin/`, and the root `plugin.json`. Point those marketplaces at this repository.

## License

[MIT](LICENSE). Copyright Wicked Sick Ltd.

Changes: [CONTRIBUTING.md](CONTRIBUTING.md). Security reports: [SECURITY.md](SECURITY.md).
