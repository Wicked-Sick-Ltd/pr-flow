---
name: pr
description: "Pull-request lifecycle \u2014 create | watch | merge | land | status | sweep. Waits for CI and every reviewer bot, triages and fixes findings, merges by the repo's rules."
---

You are running the pull-request lifecycle. **REQUIRED SKILL:** read and follow
`landing-prs` (this plugin) — it holds the rules; this command only routes.

RUN CONFIG from the user's arguments for this skill:
- VERB: the first word (`create`, `watch`, `merge`, `land`, `status`, `sweep`;
  aliases: open/raise → create, monitor/ci → watch, ship → land). No verb → `status`
  if a PR exists for the current branch, else `create`.
- PR: an optional number or URL; default the current branch's PR. Once chosen,
  that selector is the only PR for the rest of the verb.
- REPO: `--repo owner/name`; default the current repo.
- WAIT TOOL: `pr-wait.sh` lives in `skills/landing-prs/` next to this command's
  plugin root (`${PLUGIN_ROOT}/skills/landing-prs/pr-wait.sh`); run it with
  `bash`, in the background for long waits, and read its `SUMMARY` line.

Pass that PR and `--repo OWNER/NAME` on every `pr-wait.sh` invocation and every
`gh` command in the verb (`create`, `ready`, `comment`, `update-branch`,
`merge`, `list`). A bare `gh pr ready` or a helper without `--repo` resolves
the checkout, which can be a different pull request or repository. Sweep
repeats the same `--repo` with each listed PR number.

## create
1. If on `main`/`master`/`develop`: `git checkout -b fix/<slug>` (or `feat/`) first.
2. Commit the pending work (one focused commit; attribution trailer per the
   session's rules), `git push -u origin <branch>`.
3. `gh pr create --repo OWNER/NAME --base <integration branch> --title … --body …`
   with the Why / Root cause / What changed / Verification shape. Use `--draft`
   only while work is still in progress. Changes that touch auth, payments,
   migrations, infra, or secrets may start as draft.
4. Continue with **watch**, using the new PR number and the same `--repo`.
   When the agent finishes, the PR must be ready for review. **watch** runs
   `gh pr ready <PR> --repo OWNER/NAME` if it is still a draft, then waits
   again. Never leave a completed PR as draft, and never finish on the digest
   from before `gh pr ready`.

## watch
1. `bash pr-wait.sh <PR> --repo OWNER/NAME` — wait for it (it polls; do not poll
   around it).
2. Triage the digest: every failed check and every `[OPEN]` review thread gets a
   root-cause fix with a test, or a reasoned reply. Push, then re-run step 1
   on the same PR and `--repo`.
3. Stop when the helper exits 0, `checks_pending=0`, `checks_failed=0`,
   `unresolved_threads=0`, and `truncated=0`. Exit 2 with a SUMMARY means checks
   are still pending; that is not finished. If the PR is still a draft, run
   `gh pr ready <PR> --repo OWNER/NAME`, then go back to step 1. Marking a
   draft ready can start workflows and reviewer bots that did not run while it
   was a draft; the digest from before `gh pr ready` is not a result you can
   finish on. Report the fresh digest in a short table. Do **not** merge under
   this verb.

## merge
1. Run **watch** first. The precondition is watch's last digest, from after
   any `gh pr ready`. Do not merge on a digest captured while the PR was draft.
2. Merge only when the user authorized it. Authorization is this verb's
   caller having asked to merge, or `land` / `sweep` having been told to merge
   this pull request, or standing permission the user recorded for this
   repository that covers this change. Installing the plugin is not
   authorization. A repository label is not authorization. If you cannot tell
   whether the user authorized the merge, do not merge. A change that touches
   auth, payments, migrations, infra, or secrets needs authorization that
   covers that risk. If you cannot tell whether the change is in that set,
   do not merge. Refuse a draft pull request. Confirm the base branch matches
   the repository's flow (`develop` where that repo has a staging flow,
   otherwise its default branch). If it does not, stop and report it; do not
   merge. Never use `--admin`.
3. Read `merge_state` and `head=` from the pr-wait SUMMARY (`CLEAN`, `BEHIND`,
   `BLOCKED`, `UNKNOWN`, …). If it is `BEHIND` (base moved since the checks
   ran, and the repo requires an up-to-date branch), run
   `gh pr update-branch <PR> --repo OWNER/NAME`, then go back to step 1 — the
   checks must pass on the head that will actually merge. `BLOCKED` means a
   rule you cannot satisfy from here (a required review, a required check that
   never ran): report it, never `--admin` past it. `UNKNOWN`, or any other
   state you do not recognize, is not a green light: report it and do not merge.
4. `gh pr merge <PR> --repo OWNER/NAME --squash --delete-branch --match-head-commit <HEAD>`
   (`--rebase` where the repo prefers it). `<HEAD>` is the `head=` value on
   watch's last SUMMARY. If the head has changed, GitHub refuses the merge;
   go back to step 1 and watch the new head. Do not merge a commit that was
   not the one in that digest. If the repo's `AGENTS.md` names a post-merge
   deploy step, do it and verify.
5. Report: merged SHA, what deployed, what to watch next.

## land
The user invoked `land`, or asked to land, ship, or merge. That request
authorizes merge for this pull request, subject to the sensitive-change rule
in **merge**. **create**, then **merge**. The pull request is ready for review
before merge. If the request did not cover a sensitive change, or you cannot
tell, stop and ask. Never `--admin`.

## status
`bash pr-wait.sh <PR> --repo OWNER/NAME --no-wait`; answer: merged or not,
checks state, unresolved threads (quote them), anything in the comments not
yet actioned. Exit 2 with a SUMMARY means checks are still pending. If the
work is finished and the PR is still draft, run
`gh pr ready <PR> --repo OWNER/NAME` and then **watch** again. The digest from
before it was marked ready is stale.

## sweep
`gh pr list --repo OWNER/NAME --state open --json number,title,headRefName,isDraft`
for the repo (repeat with each `--repo` the user names). Run **status** on
each listed number with that same `--repo`, then **watch** the ones with
findings and **merge** the ones the user said to merge. A finished PR that is
still draft gets `gh pr ready <NUMBER> --repo OWNER/NAME`. Summarise as one
table: PR, state, failures, open threads, action taken.

## Agent runtime

Resolve `pr-wait.sh` from this plugin (`skills/landing-prs/pr-wait.sh`). Read
the repository `AGENTS.md` when it names extra gates. Use only tools that are
actually connected. Do not invent tool names.
