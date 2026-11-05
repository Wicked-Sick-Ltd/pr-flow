---
name: landing-prs
description: Use when a change is finished and needs to reach a default branch, or when asked to open/raise/create a PR, push and PR, watch/monitor/keep an eye on CI, wait for CI or reviewer/bot comments, check or deal with PR comments, fix review findings, merge (or "merge once green"), check whether a PR merged or anything was missed, ship/land it, or sweep outstanding PRs. Also use before pushing to main/master/develop for any reason.
---

# Landing PRs

A change is not done when the tests pass locally. It is done when it is on the
default branch through a pull request whose CI **and reviewer bots** have all
finished and been answered. This skill is that lifecycle; the `pr` skill is its
command form. Where your organisation publishes shipping or repository
standards, follow those gates as well.

**Violating the letter of the lifecycle is violating the spirit of it.**

## The lifecycle

1. **Branch.** Never commit on `main`/`master`/`develop`. If you are on one,
   `git checkout -b fix/<slug>` (or `feat/`) before committing. Direct pushes
   to a default branch are forbidden even when they would succeed.
2. **Open.** Push the branch; `gh pr create --repo OWNER/NAME` against the
   repo's integration branch (`develop` where the repo has a staging flow,
   else the default branch). Body: *Why / Root cause or design / What changed / Verification*,
   honest about what was not verified. **Standing rule (Craig, 5 Nov 2026):
   when the agent is finished, the PR must be ready for review — never leave a
   completed PR as draft.** Use `--draft` only while work is still in
   progress; as soon as the agent stops, run `gh pr ready <PR> --repo OWNER/NAME`
   (or create without `--draft`). Critical-tier / auth / payments / migrations /
   infra / secrets work may start as draft during WIP, but must flip to ready
   for review the moment the agent finishes so reviewers get rolling. After
   `gh pr ready <PR> --repo OWNER/NAME`, go back to step 3. Workflows and
   reviewer bots that skipped the draft may still be starting, and the digest
   from before the PR was marked ready does not count.
3. **Wait.** Run `pr-wait.sh <PR> --repo OWNER/NAME` from this skill's directory
   (see `--help`). Pass that same PR and `--repo` on every later `gh` command.
   It returns only when every check run on the head commit is terminal, and
   when reviewer bots register a check run, that is the moment reviews have
   landed too. "Checks green" before the bots finish is not green. Commit
   statuses are waited on with the check runs and count toward the same
   totals. The default poll is 90s (`--interval` or `PR_WAIT_INTERVAL`,
   minimum 60s). Each poll pages GraphQL connections (100 per page) for check
   runs, commit statuses, review threads (including every reply on a thread),
   reviews and issue comments until each connection is complete. A truncated
   page is an error, not a clean digest. Before each query, if fewer than 500
   GraphQL points remain, the script sleeps until the rate-limit reset and
   logs that. Do not poll around it, and do not pass an interval under 60s.
   The SUMMARY includes `truncated=0` only when paging finished, and `head=`
   is the commit that digest describes. Exit 0 means every listed check is
   terminal and passed. Also require `checks_pending=0`, `checks_failed=0`
   and `unresolved_threads=0`. A `--no-wait` snapshot that still has queued
   or in-progress checks prints the digest and exits 2; that is not clean.
4. **Triage.** For each failed check and each OPEN review thread in the
   digest: reproduce, fix at the root with a test (add a focused regression test), push, and go back to step 3. A
   finding you disagree with gets a reply explaining why, never silence.
   Resolve threads you addressed.
   Review comments from Claude, Bugbot, Copilot, CodeQL and Semgrep all count: every finding is fixed or answered, and every thread is resolved, before the PR counts as done.
5. **Merge** when asked to merge/land/ship, or when running autonomously on a
   non-Critical repo: `gh pr merge <PR> --repo OWNER/NAME --squash --delete-branch --match-head-commit <HEAD>`
   (rebase where the repo prefers it; use a merge commit only where the
   repository allows one). `<HEAD>` is the `head=` value on the latest pr-wait
   SUMMARY. If the head has changed since that digest, the merge refuses; go
   back to step 3 and wait on the new head. Do not merge a commit the digest
   did not cover. Read `merge_state` from that same SUMMARY. If it is `BEHIND`
   (the base moved since the checks ran), `gh pr update-branch <PR> --repo OWNER/NAME`
   and go back to step 3 — checks must pass on the head that merges. `BLOCKED`
   means a rule you cannot satisfy from here: report it. `UNKNOWN` is not
   settled: do not merge on it. Never `--admin` past a refusal.
6. **Deploy** if the repo's `AGENTS.md` names a post-merge step (for example
   `git pull` on a server with an editable install). Then report.

## When the user explicitly orders a direct push

The user's word outranks this skill, but only when it is explicit and
reaffirmed. If the user says to push to a default branch directly: state the
policy in one sentence and ask them to confirm. If they reaffirm, do it, and in
the same turn open a follow-up PR or issue that records the bypass and what
still needs reviewing. Urgency you inferred yourself is not an order.

## Quick reference

| Ask | Do |
|---|---|
| "push and create a PR", "raise the PR" | steps 1–3, report the digest |
| "watch CI", "keep an eye on the PR", "wait for comments and fix" | steps 3–4 until clean |
| "merge", "merge once green", "ship it", "land it" | steps 3–6 |
| "did this merge?", "anything missed in the comments?" | `pr-wait.sh <PR> --repo OWNER/NAME --no-wait`, then report |
| "check all outstanding PRs" | `gh pr list --repo OWNER/NAME`, then this table per PR |

## Rationalisations (all observed, all wrong)

| Excuse | Reality |
|---|---|
| "Small fix, straight to main is fine" | Main pushes skip the bots and hide CI breakage. |
| "Local suite is green" | Local is not CI. CI is the gate. |
| "All checks passed" | Reviewer bots post minutes later; the digest says when you are done. |
| "The bot comment is a nit" | Reply with the reason. An unanswered thread is an unfinished PR. |
| "Deploy now, PR later" | Deploy follows merge. |
| "Leave it draft until someone asks" | Finished work stays invisible to reviewers. Mark ready when the agent stops. |

## Red flags

`git push origin main` · reporting before `pr-wait.sh` returned ·
`unresolved_threads>0` in a final report · `gh pr merge --admin` · a finished
agent's pull request left as draft.

## Agent runtime

Resolve `pr-wait.sh` beside this `SKILL.md`. Read the repository `AGENTS.md`
when it names extra gates. Use only tools that are actually connected. Do not
invent tool names.
