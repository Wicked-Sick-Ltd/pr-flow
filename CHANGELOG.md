# Changelog

## 1.1.0 (2026-11-05)

### Changed

- This repository is the canonical MIT home of PR Flow. Marketplace copies and `ai-*-repo` checkouts should vendor or sync from here.
- License is MIT, copyright Wicked Sick Ltd. Plugin manifests name this repository.
- `landing-prs`: when an agent finishes, the pull request must be ready for review. Draft is only for work in progress. Critical-tier and sensitive changes may start as draft and flip to ready when the agent finishes.
- Skill text points at your organisation's shipping and repository standards. It no longer names one internal conventions document.

## 1.0.0 (2026-10-31)

### Added

- `landing-prs`, `pr`, and `pr-wait.sh`, with Cursor, Claude, Codex and portable plugin manifests.
- Review comments from Claude, Bugbot, Copilot, CodeQL and Semgrep all count. Every finding is fixed or answered, and every thread is resolved, before the PR counts as done.
