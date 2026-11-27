---
name: merge-attribution
description: Use every time an agent merges a pull request (by hand, by a sweep or by auto-merge), and when asked which pull requests merged on a day, which agent merged them and under which rule, or which merges have no attribution.
---

# Merge attribution

Every merge an agent makes must be traceable without anyone asking. This skill
adds attribution only. It never grants permission to merge: `landing-prs` still
decides whether the merge is authorized.

GitHub is the merge log. The merge record plus one comment on the pull request
is the whole entry. There is no second list to find, keep or append to.

## On every merge

1. Once the merge is confirmed (`gh pr view <PR> --repo OWNER/NAME --json state,mergeCommit`
   shows `MERGED` with a merge commit), post one comment on the pull request:
   `Merged by <agent name> under <rule name> (<where and when the rule was granted>). CI: green. Unresolved threads: none.`
   For example:
   `Merged by Claude Code under explicit go from the owner (in session, 2026-11-27 17:15 UTC). CI: green. Unresolved threads: none.`
   The comment starts with `Merged by`, the rule name follows `under`, and
   where and when it was granted goes inside the parentheses. The daily list
   finds and groups merges by that opening, so write it exactly.
   Never post it before the merge is confirmed. A refused merge (for example
   `--match-head-commit` rejecting a moved head) or auto-merge that is only
   enabled is not a merge, so no comment yet.
   Name the actual rule, for example "low-blast-radius self-merge",
   "tests/CI-only self-merge", "staging branch", or "explicit go from the owner".
2. If the merge reaches a live site and the agent's rules require an update
   post, make it in that site's usual channel.

## Bulk merges

- A sweep that merges more than 5 pull requests in one run posts a single
  summary (count, repositories, rule) to the owner's usual channel before the
  run ends, not afterwards when asked.
- Never merge under a generic bot account without the comment. An unattributed
  merge is a defect to report.

## Daily merge list

The list is read from GitHub, not from anything an agent wrote down, so a merge
with no comment still appears on it.

- Once a day, whoever owns the daily ops audit runs the `merge-audit.sh` beside
  this `SKILL.md`, naming every GitHub user or organisation the agents merge in:
  `bash merge-audit.sh --owner OWNER [--owner OWNER ...]`
  The day defaults to today in UTC. `--date YYYY-MM-DD` picks another day and
  `--help` lists the rest.
- Send the owner its output as it is: merges with no attribution comment first,
  then any it could not check, then the rest grouped by agent and rule. The
  helper cannot tell a person's own merge from an agent that skipped the
  comment, so it prints who merged each one.
- A comment counts only when it was posted at or after the merge, by the account
  that merged or by an owner, member or collaborator of the repository. So post
  the attribution from the account that ran the merge.
- Exit 1 means at least one merge is unattributed or unchecked. Exit 3 means the
  list could not be completed: run it again, and if it fails again report that.
  Do not send part of a day as the day's list.
- A day with no merges sends nothing.
