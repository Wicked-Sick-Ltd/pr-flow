# Security policy

## Supported versions

Security fixes land on the `main` branch. The current plugin release is **1.1.0**.

## Reporting a vulnerability

Email **hello@wickedsick.com** with `[pr-flow security]` in the subject. That address is the author contact published in the plugin manifests. Include the plugin version or commit, the agent host (Cursor, Claude, Codex, Copilot, or another), and steps to reproduce. Leave credentials, tokens, and customer data out of the report.

Use that email for security reports. Keep vulnerability details out of public issues and pull requests.

GitHub's **Security → Report a vulnerability** form is a second channel only after both of these are true: this repository is public, and a maintainer has enabled private vulnerability reporting. This policy does not claim that form is enabled. Until it is, email is the channel that accepts a report. After it is enabled, either channel is fine, and the email stays open.

You can expect an acknowledgement within a few days.

## After this repository is public

These steps are for maintainers. They are not done by installing the plugin.

1. Enable private vulnerability reporting, then confirm the form accepts a test report from a maintainer.
2. Leave the email above in this file. The form does not replace it.
3. Submit the package to a public marketplace only after the repository is public. Listed plugins are open source, and this package is MIT.

## Scope

The package is a local skill plus `skills/landing-prs/pr-wait.sh`. The helper shells out to the GitHub CLI (`gh`) as the person who runs it. It does not embed credentials. Reports about how the helper handles GitHub responses, subprocesses, or temporary files belong here. Reports about GitHub, the `gh` CLI, or the agent host belong with those projects.
