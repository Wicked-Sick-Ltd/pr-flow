# Security policy

## Supported versions

Security fixes land on the `main` branch. The current plugin release is **1.1.0**.

## Reporting a vulnerability

Email **hello@wickedsick.com** with `[pr-flow security]` in the subject. That address is the author contact published in the plugin manifests. Include the plugin version or commit, the agent host (Cursor, Claude, Codex, Copilot, or another), and steps to reproduce. Leave credentials, tokens, and customer data out of the report.

Use that email for security reports. Keep vulnerability details out of public issues and pull requests.

This repository is private. GitHub private vulnerability reporting applies to public repositories, so the **Security → Report a vulnerability** form is a later path: once this repository is public and maintainers have enabled it, that form accepts reports too. The email above stays open either way.

You can expect an acknowledgement within a few days.

## Scope

The package is a local skill plus `skills/landing-prs/pr-wait.sh`. The helper shells out to the GitHub CLI (`gh`) as the person who runs it. It does not embed credentials. Reports about how the helper handles GitHub responses, subprocesses, or temporary files belong here. Reports about GitHub, the `gh` CLI, or the agent host belong with those projects.
