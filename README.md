# pr-flow

Canonical MIT home of **PR Flow** and the **landing-prs** skill, maintained by
**Wicked Sick Ltd**.

This repository is the source of truth for the plugin. Keep it private until
it is explicitly made public for the Cursor Marketplace and other agent
marketplaces. `ai-*-repo` checkouts and `Wicked-Sick-Ltd/ai-marketplace`
should vendor or sync from here. See [VENDORED.md](VENDORED.md).

The plugin opens a pull request, waits until CI and reviewer bots finish,
answers every finding, and lands the change only when the digest is clean.
When an agent finishes, the pull request is **ready for review**. Draft is
only for work still in progress. Critical-tier and sensitive changes may
start as draft, then flip to ready when the agent stops.

Marketplace listing (Cursor and other agent marketplaces) waits until this
repository is public.

## Install for Cursor

The tree is both a Cursor plugin (`.cursor-plugin/plugin.json`) and an Agent
Plugin (`plugin.json` at the root).

**On your machine.** Clone this repository and copy it to
`~/.cursor/plugins/local/pr-flow` (the copy must live inside that folder).
Reload Cursor, then open **Customize** and confirm `landing-prs` and `pr`.
Enterprise admins must allow local plugin imports.

**For a team.** In the Cursor dashboard, open **Plugins & MCPs**, add a team
marketplace with **Import from Repo**, and paste:

`https://github.com/Wicked-Sick-Ltd/pr-flow`

Add the `pr-flow` plugin and set who can install it. The Cursor GitHub App
needs access to this repository. Turn on **Auto Refresh** if you want pushes
here to update the marketplace index.

**Cursor Marketplace.** After the repository is public, submit it at
[cursor.com/marketplace/publish](https://cursor.com/marketplace/publish).
Listed plugins have to be open source; this package is MIT.

## Other agents

Claude, Codex and Copilot manifests live in `.claude-plugin/`,
`.codex-plugin/` and the root `plugin.json`. Point those marketplaces at this
repository instead of an older catalogue copy. Start a new session after
installing.

## What is in the package

- [landing-prs](skills/landing-prs/SKILL.md): policy for opening, watching,
  reviewing and landing a change.
- [pr](skills/pr/SKILL.md): `create|watch|merge|land|status|sweep`, with an
  optional PR number or URL and `--repo owner/name`.
- [pr-wait.sh](skills/landing-prs/pr-wait.sh): wait for check runs and commit
  statuses, then print checks, reviews, unresolved threads and comments.
  Each poll pages GraphQL connections (100 per page) until checks, reviews,
  threads, thread replies and comments are complete. Default interval 90 seconds (minimum 60).
  Sleeps until the rate-limit reset when fewer than 500 points remain. A
  truncated page is an error, not a clean digest.

`watch` stops after triage. `land` merges when that is authorized. Keep the
repository's branch rules. A zero exit from the helper means every listed
check is terminal and passed. A snapshot with checks still pending exits 2.
Before merging, require `unresolved_threads=0` and pass the SUMMARY `head=`
value to `gh pr merge --match-head-commit`. That line also reports
`mergeable` and `merge_state`. Pass the selected PR and `--repo` on every
helper and `gh` command.

Review comments from Claude, Bugbot, Copilot, CodeQL and Semgrep are in scope.
Every finding is fixed or answered, and every thread is resolved, before the
PR counts as done.

## Dependencies

Requires authenticated `gh`, Bash and `jq`. On Windows use Git Bash or WSL
with those tools on `PATH`. Resolve the helper from the installed skill
folder.

## License

[MIT](LICENSE). Copyright Wicked Sick Ltd.
