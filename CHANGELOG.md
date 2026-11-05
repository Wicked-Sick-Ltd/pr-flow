# Changelog

## 1.1.0 (2026-11-05)

### Fixed

- `pr-wait.sh` pages check, review, thread, thread-reply and comment connections and refuses a partial digest. Pages are joined from files so a large page cannot be dropped by the argument-size limit. Pass/fail ignores a concurrency-cancelled run only when a later run of that same check and workflow passed. A commit status is counted on its own, even when its name matches a check run. Stale and any other completed conclusion besides success, neutral and skipped are failures. A timeout during the settle window still prints the digest when every listed check is already complete. With no PR argument it passes the current branch to `gh pr view`.
- `pr`: after `gh pr ready`, wait again. The digest from before the PR was marked ready is not a clean result.

### Changed

- This repository is the canonical MIT home of PR Flow. Marketplace copies and `ai-*-repo` checkouts should vendor or sync from here.
- License is MIT, copyright Wicked Sick Ltd. Plugin manifests name this repository.
- `landing-prs`: when an agent finishes, the pull request must be ready for review. Draft is only for work in progress. Critical-tier and sensitive changes may start as draft and flip to ready when the agent finishes.
- Skill text points at your organisation's shipping and repository standards. It no longer names one internal conventions document.

## 1.0.0 (2026-10-31)

### Added

- `landing-prs`, `pr`, and `pr-wait.sh`, with Cursor, Claude, Codex and portable plugin manifests.
- Review comments from Claude, Bugbot, Copilot, CodeQL and Semgrep all count. Every finding is fixed or answered, and every thread is resolved, before the PR counts as done.
