# Contributing to pr-flow

Bug reports, fixes, and small improvements are welcome. This repository is the canonical plugin. Send changes here. Vendored copies, including `Wicked-Sick-Ltd/ai-marketplace`, follow this tree.

## Proposing a change

1. Open an issue, or a pull request against `main`, that says why the change is needed.
2. Branch from `main`. Keep each pull request to one focused change.
3. A finished pull request is ready for review. Use a draft while the work is still in progress.
4. In the body, cover why, what changed, and how you verified it.

Security reports go through [SECURITY.md](SECURITY.md).

## Pull request expectations

- Skill text and `pr-wait.sh` stay in agreement. A behavior change updates the skill, the helper, and [CHANGELOG.md](CHANGELOG.md) together.
- Put user-visible notes under `## Unreleased` in the changelog. Leave shipped version headings as they are.
- Keep `version` identical in `plugin.json`, `.cursor-plugin/plugin.json`, `.claude-plugin/plugin.json`, and `.codex-plugin/plugin.json`. Bump those fields when cutting a release.
- `skills/landing-prs/pr-wait.sh`, `skills/landing-prs/pr-wait_test.sh`, `skills/merge-attribution/merge-audit.sh` and `skills/merge-attribution/merge-audit_test.sh` stay executable.
- Keep secrets, tokens, and customer data out of the diff and the discussion.

## Tests

The helper's regression tests use a fake `gh` and `git`. They need Bash, `jq`, and Python 3 (the large-review fixture is generated with `python3`). They make no network calls:

```bash
bash skills/landing-prs/pr-wait_test.sh
bash skills/merge-attribution/merge-audit_test.sh
```

Run the first before asking for review when you touch `pr-wait.sh` or its test, and the second when you touch `merge-audit.sh` or its test. The second needs only Bash and `jq`. GitHub Actions runs both.

`--dry-run` prints the helper's settings and does not call GitHub:

```bash
bash skills/landing-prs/pr-wait.sh --dry-run
```

That script is the smoke check. It does not target a live pull request.

## Style

Match the surrounding prose: short sentences and concrete commands. Bash stays plain `bash` with `set -uo pipefail`, with no extra runtimes or package managers. Keep the helper's exit codes (`0` clean, `1` failed, `2` pending or timeout, `3` usage). Comment a constraint the next reader would otherwise have to rediscover.
