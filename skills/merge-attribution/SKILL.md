---
name: merge-attribution
description: Use every time an agent merges a pull request (by hand, by a sweep or by auto-merge), so the owner can always see which agent merged it and under which rule.
---

# Merge attribution

Every merge an agent makes must be traceable without anyone asking. This skill
adds attribution only. It never grants permission to merge: `landing-prs` still
decides whether the merge is authorized.

## On every merge

1. Just before or right after merging, post one comment on the pull request:
   `Merged by <agent name> under <rule name> (<where and when the rule was granted>). CI: green. Unresolved threads: none.`
   Name the actual rule, for example "low-blast-radius self-merge",
   "tests/CI-only self-merge", "staging branch", or "explicit go from the owner,
   <date and time>".
2. Append one line to the shared daily merge log. Use the path or page named in
   the agent's instructions or in the owner's recorded standing permissions:
   `<UTC time> | <repo>#<number> | <title> | <agent> | <rule> | <merge sha>`
3. If the merge reaches a live site and the agent's rules require an update
   post, make it in that site's usual channel.

## Bulk merges

- A sweep that merges more than 5 pull requests in one run posts a single
  summary (count, repositories, rule) to the owner's usual channel before the
  run ends, not afterwards when asked.
- Never merge under a generic bot account without the comment. An unattributed
  merge is a defect to report.

## Daily merge list

- Once a day, whoever owns the daily ops audit reads the log and sends the owner
  a short list grouped by agent and rule, with any merge missing its attribution
  comment flagged first.
- A day with no merges sends nothing.
