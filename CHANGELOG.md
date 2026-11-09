# Changelog

## Unreleased

### Added

- Marketplace-facing README, CONTRIBUTING.md, SECURITY.md, and a GitHub Actions run of `skills/landing-prs/pr-wait_test.sh`. Docs and repository hygiene only. The plugin release remains 1.1.0.

### Changed

- `landing-prs` and `pr` merge only when the installing user has explicitly asked, or has recorded standing permission that covers the change. Installing the plugin is not permission to merge, and neither is a repository label. Unknown merge state, or a sensitive change the request does not cover, does not merge. Finished work is still ready for review, and `--admin` is still refused. The plugin release remains 1.1.0.
- SECURITY.md no longer describes repository visibility. Email remains the report channel. GitHub's vulnerability form is described as available only after the repository is public and a maintainer has enabled it.
- Current docs name this repository as the vendor source for marketplace copies.

## 1.1.0 (2026-11-05)

### Fixed

- `pr-wait.sh` pages check, review, thread, thread-reply and comment connections and refuses a partial digest. Pages are joined from files so a large page cannot be dropped by the argument-size limit. Pass/fail ignores a concurrency-cancelled run only when a later run of that same check passed. The check identity is the workflow database id, else its path, else the app id or slug; the workflow display name is only a fallback. A commit status is counted on its own, even when its name matches a check run. Stale and any other completed conclusion besides success, neutral and skipped are failures. A timeout during the settle window still prints the digest when every listed check is already complete. `--no-wait` prints the digest and exits 2 while any check is still pending. If the pull request head is not the commit the checks were read from, the digest exits 2 and `head=` stays that checked commit. With no PR argument it passes the current branch to `gh pr view`. The SUMMARY includes `head=`.
- `pr` and `landing-prs`: every helper and `gh` command carries the selected PR and `--repo`. After `gh pr ready`, wait again. Merge passes `--match-head-commit` from that digest and waits again if the head moved.

### Changed

- This repository is the canonical MIT home of PR Flow. Marketplace copies should vendor or sync from here.
- License is MIT, copyright Wicked Sick Ltd. Plugin manifests name this repository.
- `landing-prs`: when an agent finishes, the pull request must be ready for review. Draft is only for work in progress. Critical-tier and sensitive changes may start as draft and flip to ready when the agent finishes.
- Skill text points at your organisation's shipping and repository standards. It no longer names one internal conventions document.

## 1.0.0 (2026-10-31)

### Added

- `landing-prs`, `pr`, and `pr-wait.sh`, with Cursor, Claude, Codex and portable plugin manifests.
- Review comments from Claude, Bugbot, Copilot, CodeQL and Semgrep all count. Every finding is fixed or answered, and every thread is resolved, before the PR counts as done.
