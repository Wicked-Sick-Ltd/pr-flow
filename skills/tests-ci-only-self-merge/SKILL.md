---
name: tests-ci-only-self-merge
description: Use when an agent's own CI-green pull request on a live repository touches only tests or CI config, to decide whether the agent may merge it without waiting for the owner, where the owner has recorded standing permission for this.
---

# Tests/CI-only self-merge on live repositories

This is a narrow standing permission, not a default. It applies only where the
owner has recorded it (see `landing-prs` step 5: installing the plugin is not
authorization). An agent may merge its own pull request on a live repository
without waiting for the owner only when every check below passes. If any check
fails or is unclear, leave the pull request for the owner.

## The diff must touch only

- Test files and test fixtures (for example `tests/`, `__tests__/`, `*.test.*`,
  `*.spec.*`, `spec/`, fixture or snapshot data used only by tests).
- CI workflow config that runs tests, lint or scans (jobs for test, lint or
  security tests, and test config such as `jest.config`, `phpunit.xml`,
  `pytest.ini`).

## The diff must not

- Change application code, templates, routes, migrations, build output, or
  dependencies used at runtime.
- Touch deploy or release workflows, environment files, secrets, tokens,
  `permissions:` blocks, branch protection, CODEOWNERS, or runners.
- Remove, skip or weaken a required check, test or security scan (no
  `continue-on-error`, `if: false`, deleted tests or loosened thresholds),
  unless the pull request replaces it with an equal or stronger check.

## Other conditions

- All required checks are green and there are no unresolved review threads,
  per the `landing-prs` digest on the exact head being merged.
- The repository's one-agent-per-repo rule, or a declared fan-out, is respected.
- Repositories the owner excludes stay excluded even for tests/CI-only pull
  requests. Typical exclusions: auth or SSO, payments, infrastructure or DNS,
  sensitive-data repositories, client repositories, and any repository on an
  explicit hold.

## When merging

Follow `merge-attribution`: comment on the pull request naming the agent and
"tests/CI-only self-merge", and add the merge to the daily merge log.
