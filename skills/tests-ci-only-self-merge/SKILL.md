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

## This adds to `landing-prs`, never replaces it

Every `landing-prs` gate still applies: the clean digest on the exact head
(`--match-head-commit`), a draft is marked ready and re-waited first, and
`--admin` is never used. Critical-tier repositories and sensitive changes need
an explicit owner go regardless of this skill, and where `landing-prs` allows
less than this skill, `landing-prs` wins. The permission here only removes the
wait for the owner on changes that pass every check below.

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
- Add or change any `uses:` action or version pin, `on:` trigger (especially
  `pull_request_target`, `workflow_run` or `schedule`), `secrets.*` or
  `GITHUB_TOKEN` reference, `env:` that exposes credentials, download or
  network step, or any job that runs with secrets or write access. Workflow
  edits are limited to the arguments and selection of existing test, lint or
  scan commands in jobs that already run without secrets. Anything else is for
  the owner, because workflow steps execute later with the job's credentials.
- Remove, skip or weaken a required check, test or security scan (no
  `continue-on-error`, `if: false`, deleted tests or loosened thresholds),
  unless the pull request replaces it with an equal or stronger check.

## Other conditions

- All required checks are green and there are no unresolved review threads,
  per the `landing-prs` digest on the exact head being merged.
- Any rule the repository or organisation sets for concurrent agents (for
  example an agents file or shipping standards that limit work to one agent per
  repository, or declare a fan-out) is respected. If you cannot tell, leave it
  for the owner.
- Repositories the owner excludes stay excluded even for tests/CI-only pull
  requests. Typical exclusions: Critical-tier repositories, auth or SSO, payments, infrastructure or DNS,
  sensitive-data repositories, client repositories, and any repository on an
  explicit hold.

## When merging

Follow `merge-attribution`: comment on the pull request naming the agent and
"tests/CI-only self-merge", and add the merge to the daily merge log.
