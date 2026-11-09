# PR Flow

Open a GitHub pull request, wait until CI and reviewer bots finish, answer every finding, and merge only when the user has authorized it and the digest is clean.

**PR Flow** is the MIT-licensed agent plugin for that lifecycle, maintained by Wicked Sick Ltd. The rules live in [landing-prs](skills/landing-prs/SKILL.md). The command form is [pr](skills/pr/SKILL.md) (`create`, `watch`, `merge`, `land`, `status`, `sweep`). The wait step is [pr-wait.sh](skills/landing-prs/pr-wait.sh). Current release: **1.1.0**.

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

## Requirements

- [GitHub CLI](https://cli.github.com/) (`gh`), authenticated for the repositories you land
- Bash
- [`jq`](https://jqlang.org/)

On Windows, use Git Bash or WSL with those tools on `PATH`. Resolve `pr-wait.sh` from the installed skill folder (`skills/landing-prs/` beside this plugin).

## Other agents

Claude, Codex, and Copilot manifests live in `.claude-plugin/`, `.codex-plugin/`, and the root `plugin.json`. Point those marketplaces at this repository.

## License

[MIT](LICENSE). Copyright Wicked Sick Ltd.

Changes: [CONTRIBUTING.md](CONTRIBUTING.md). Security reports: [SECURITY.md](SECURITY.md).
