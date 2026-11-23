#!/usr/bin/env bash
# HELP-START
# pr-wait.sh — wait until every check run and reviewer bot on a pull request has
# finished, then print a triage digest (checks, reviews, unresolved review
# threads, comments) that an agent can act on line by line.
#
# Why a script: reviewer bots (Cursor Bugbot, Claude Code
# Review, Copilot, CodeQL, Semgrep, test workflows) register a check run on
# the head commit and posts its review the moment that run completes. So "all
# check runs terminal" is the one predicate that means both CI and the bots
# are done — polling `gh pr checks` alone misses reviews that land late.
# Commit statuses (the older status API) are waited on and counted with the
# check runs.
#
# Each poll pages GraphQL connections (100 items per page) for check runs,
# commit statuses, review threads, reviews and issue comments until each
# connection is complete. A truncated page is not a digest: the script stops
# with an error instead of reporting the first page as clean. Before every
# query the script reads the GraphQL rateLimit (a one-point probe on the first
# poll, then the rateLimit object on the previous response). When fewer than
# 500 points remain it sleeps until resetAt and logs that, so the caller's
# GitHub rate limit is not exhausted.
#
# Usage:
#   pr-wait.sh [PR-number | branch | URL] [--repo OWNER/NAME] [--timeout SECS]
#              [--interval SECS] [--grace SECS] [--settle SECS] [--no-wait]
#              [--dry-run]
#   Defaults: current branch's PR, current repo, timeout 3600, interval 90,
#   grace 120 (how long to wait for the first check run to register), settle 90
#   (how long the set of completed runs must stay unchanged before we believe
#   nothing else — a reviewer bot, a `needs:` job — is still about to register).
#   A new head commit restarts the wait. PR_WAIT_RETRY_SLEEP (default 5)
#   spaces the retries of a failing gh call. PR_WAIT_INTERVAL sets the poll
#   interval when --interval is omitted (default 90). The interval must be at
#   least 60 seconds; a smaller value is a usage error.
#   --dry-run prints the effective settings and does not call GitHub.
# Exit codes:
#   0 every listed check is terminal and passed/neutral/skipped
#   1 a check failed, was cancelled or timed out
#   2 gave up waiting (timeout), or the snapshot still has pending checks
#   3 usage, or gh kept failing (never reported as green)
#   --no-wait prints one snapshot and returns immediately. Exit 0 still
#   requires every listed check to be terminal. Pending checks exit 2
#   after the digest.
# Needs: gh (authenticated), jq. Plain bash, no other deps. --dry-run needs neither.
# HELP-END
set -uo pipefail

# Fewer than this many GraphQL points remaining → sleep until the window resets.
RATE_FLOOR=500
MIN_INTERVAL=60

PR=""
REPO=""
REPO_EXPLICIT=0
TIMEOUT=3600
INTERVAL="${PR_WAIT_INTERVAL:-90}"
GRACE=120
SETTLE=90
NOWAIT=0
DRYRUN=0
RETRY_SLEEP="${PR_WAIT_RETRY_SLEEP:-5}"
LAST_REMAINING=""
LAST_RESET=""

usage() {
  awk '
    /^# HELP-START$/ { show = 1; next }
    /^# HELP-END$/ { exit }
    show { sub(/^# ?/, ""); print }
  ' "$0"
}

PR_WAIT_WORK=""
die() {
  echo "pr-wait: $*" >&2
  if [ -n "${PR_WAIT_WORK:-}" ]; then
    rm -rf "$PR_WAIT_WORK"
  fi
  exit 3
}

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)
      [ $# -ge 2 ] || die "--repo needs a value"
      REPO="$2"; REPO_EXPLICIT=1; shift 2;;
    --timeout)
      [ $# -ge 2 ] || die "--timeout needs a value"
      TIMEOUT="$2"; shift 2;;
    --interval)
      [ $# -ge 2 ] || die "--interval needs a value"
      INTERVAL="$2"; shift 2;;
    --grace)
      [ $# -ge 2 ] || die "--grace needs a value"
      GRACE="$2"; shift 2;;
    --settle)
      [ $# -ge 2 ] || die "--settle needs a value"
      SETTLE="$2"; shift 2;;
    --no-wait) NOWAIT=1; shift;;
    --dry-run) DRYRUN=1; shift;;
    -h|--help) usage; exit 0;;
    --*) echo "pr-wait: unknown option $1" >&2; exit 3;;
    *) PR="$1"; shift;;
  esac
done

case "$INTERVAL" in
  ''|*[!0-9]*) die "interval must be a whole number of seconds (got '${INTERVAL}')";;
esac
if [ "$((10#$INTERVAL))" -lt "$MIN_INTERVAL" ]; then
  die "interval ${INTERVAL}s is below the minimum of ${MIN_INTERVAL}s"
fi

if [ "$DRYRUN" -eq 1 ]; then
  printf 'pr-wait: dry-run interval=%s timeout=%s grace=%s settle=%s rate_floor=%s min_interval=%s repo=%s pr=%s\n' \
    "$INTERVAL" "$TIMEOUT" "$GRACE" "$SETTLE" "$RATE_FLOOR" "$MIN_INTERVAL" \
    "${REPO:-(unset)}" "${PR:-(current branch)}"
  echo "pr-wait: dry-run poll=graphql checks+statuses+reviewThreads+mergeability"
  exit 0
fi

command -v gh >/dev/null || die "gh not found"
command -v jq >/dev/null || die "jq not found"

# gh_try LABEL gh-args... — up to 3 attempts; prints stdout of the first success.
# A persistent failure is fatal (exit 3): a rate limit or 502 must never be
# read back as "no checks", "no threads" or "no comments".
gh_try() {
  local label="$1"
  shift
  local attempt=1 out err cmd="$1"
  err="$(mktemp)" || die "mktemp failed"
  while [ "$attempt" -le 3 ]; do
    if out="$(gh "$@" 2>"$err")"; then
      rm -f "$err"
      printf '%s' "$out"
      return 0
    fi
    if [ "$attempt" -lt 3 ]; then
      sleep "$RETRY_SLEEP"
    fi
    attempt=$((attempt + 1))
  done
  local msg
  msg="$(tr '\n' ' ' <"$err" 2>/dev/null || true)"
  rm -f "$err"
  die "$label failed 3 times (gh ${cmd} ...): ${msg}"
}

# One page of a poll. Each connection is at most 100 nodes; follow endCursor
# until hasNextPage is false. Replies on a review thread are paged the same
# way. Do not add another nested connection without rechecking the point cost
# (nodes/100, minimum 1, plus thread comments).
POLL_QUERY=$(cat <<'EOF'
query($owner:String!, $name:String!, $number:Int!, $contextsAfter:String, $reviewsAfter:String, $threadsAfter:String, $commentsAfter:String) {
  rateLimit { remaining resetAt cost }
  repository(owner:$owner, name:$name) {
    pullRequest(number:$number) {
      number
      url
      state
      mergeable
      mergeStateStatus
      headRefOid
      headRefName
      baseRefName
      commits(last:1) {
        nodes {
          commit {
            oid
            statusCheckRollup {
              contexts(first:100, after:$contextsAfter) {
                pageInfo { hasNextPage endCursor }
                nodes {
                  __typename
                  ... on CheckRun {
                    databaseId
                    name
                    status
                    conclusion
                    title
                    checkSuite { app { name slug databaseId } workflowRun { workflow { databaseId name resourcePath } } }
                  }
                  ... on StatusContext {
                    context
                    state
                    description
                  }
                }
              }
            }
          }
        }
      }
      reviews(first:100, after:$reviewsAfter) {
        pageInfo { hasNextPage endCursor }
        nodes { submittedAt state body author { login } }
      }
      reviewThreads(first:100, after:$threadsAfter) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          isResolved
          isOutdated
          path
          line
          comments(first:100) {
            pageInfo { hasNextPage endCursor }
            nodes { author { login } body }
          }
        }
      }
      comments(first:100, after:$commentsAfter) {
        pageInfo { hasNextPage endCursor }
        nodes { createdAt body author { login } }
      }
    }
  }
}
EOF
)

PARSE_JQ=$(cat <<'EOF'
def lc: ascii_downcase;
.data as $root
| $root.repository.pullRequest as $pr
| ($pr.commits.nodes[0].commit // null) as $commit
| ($commit.statusCheckRollup.contexts // null) as $contexts
| {
    number: $pr.number,
    url: $pr.url,
    state: $pr.state,
    base: $pr.baseRefName,
    sha: $pr.headRefOid,
    commit: ($commit.oid // null),
    mergeable: ($pr.mergeable // "UNKNOWN"),
    merge_state: ($pr.mergeStateStatus // "UNKNOWN"),
    remaining: $root.rateLimit.remaining,
    resetAt: $root.rateLimit.resetAt,
    checks_more: ($contexts.pageInfo.hasNextPage // false),
    checks_cursor: ($contexts.pageInfo.endCursor // ""),
    threads_more: ($pr.reviewThreads.pageInfo.hasNextPage // false),
    threads_cursor: ($pr.reviewThreads.pageInfo.endCursor // ""),
    reviews_more: ($pr.reviews.pageInfo.hasNextPage // false),
    reviews_cursor: ($pr.reviews.pageInfo.endCursor // ""),
    comments_more: ($pr.comments.pageInfo.hasNextPage // false),
    comments_cursor: ($pr.comments.pageInfo.endCursor // ""),
    checks: (
      ($contexts.nodes // [])
      | map(
          if .__typename == "CheckRun" then {
            id: (.databaseId // .name),
            kind: "check",
            name: (.name // "check"),
            workflow: (.checkSuite.workflowRun.workflow.name // .checkSuite.app.name // ""),
            group: (
              if .checkSuite.workflowRun.workflow.databaseId != null then
                "workflow:" + (.checkSuite.workflowRun.workflow.databaseId | tostring)
              elif (.checkSuite.workflowRun.workflow.resourcePath // "") != "" then
                "path:" + .checkSuite.workflowRun.workflow.resourcePath
              elif .checkSuite.app.databaseId != null then
                "app:" + (.checkSuite.app.databaseId | tostring)
              elif (.checkSuite.app.slug // "") != "" then
                "app:" + .checkSuite.app.slug
              elif (.checkSuite.workflowRun.workflow.name // "") != "" then
                "name:" + .checkSuite.workflowRun.workflow.name
              elif (.checkSuite.app.name // "") != "" then
                "name:" + .checkSuite.app.name
              else "" end
            ),
            status: ((.status // "PENDING") | lc),
            conclusion: (if .conclusion == null then null else (.conclusion | lc) end),
            output: {title: (.title // "")}
          }
          elif .__typename == "StatusContext" then {
            id: ("status:" + (.context // "status")),
            kind: "status",
            workflow: "",
            name: (.context // "status"),
            status: (if (.state == "PENDING" or .state == "EXPECTED") then "pending" else "completed" end),
            conclusion: (
              if .state == "SUCCESS" then "success"
              elif (.state == "FAILURE" or .state == "ERROR") then "failure"
              else null end
            ),
            output: {title: (.description // "")}
          }
          else empty end
        )
    ),
    reviews: [
      $pr.reviews.nodes[]?
      | {
          submitted_at: .submittedAt,
          state: .state,
          body: (.body // ""),
          user: {login: (.author.login // "unknown")}
        }
    ],
    threads: [
      $pr.reviewThreads.nodes[]?
      | {
          id: (.id // ""),
          isResolved: .isResolved,
          isOutdated: .isOutdated,
          path: .path,
          line: .line,
          comments_more: (.comments.pageInfo.hasNextPage // false),
          comments_cursor: (.comments.pageInfo.endCursor // ""),
          comments: {
            nodes: [
              .comments.nodes[]?
              | {body: (.body // ""), author: {login: (.author.login // "unknown")}}
            ]
          }
        }
    ],
    comments: [
      $pr.comments.nodes[]?
      | {
          created_at: .createdAt,
          body: (.body // ""),
          user: {login: (.author.login // "unknown")}
        }
    ]
  }
EOF
)

now() { date +%s; }

# resetAt is UTC ISO-8601 (2026-10-30T09:34:10Z). jq parses that on macOS and
# Linux. Do not shell out to date for this value: the GNU and BSD flags differ.
epoch_of() {
  local raw="$1" trimmed epoch
  if ! epoch="$(jq -nr --arg t "$raw" '$t | fromdateiso8601' 2>/dev/null)"; then
    epoch=""
  fi
  if [ -z "$epoch" ]; then
    trimmed="${raw%%.*}"
    case "$trimmed" in
      *Z) ;;
      *) trimmed="${trimmed}Z" ;;
    esac
    if ! epoch="$(jq -nr --arg t "$trimmed" '$t | fromdateiso8601' 2>/dev/null)"; then
      epoch=""
    fi
  fi
  if [ -z "$epoch" ]; then
    return 1
  fi
  printf '%s' "$epoch"
}

note_rate_limit() {
  local remaining="$1" reset="$2"
  case "$remaining" in
    ''|*[!0-9]*) die "rate limit response missing remaining";;
  esac
  if [ -z "$reset" ] || [ "$reset" = null ]; then
    die "rate limit response missing resetAt"
  fi
  LAST_REMAINING="$remaining"
  LAST_RESET="$reset"
}

read_rate_limit() {
  local raw
  raw="$(gh_try "rate limit" api graphql -f query='query { rateLimit { remaining resetAt } }')"
  if jq -e '(.errors // []) | length > 0' >/dev/null <<<"$raw"; then
    die "rate limit query failed: $(jq -r '[(.errors // [])[].message] | join("; ")' <<<"$raw")"
  fi
  note_rate_limit \
    "$(jq -r '.data.rateLimit.remaining // empty' <<<"$raw")" \
    "$(jq -r '.data.rateLimit.resetAt // empty' <<<"$raw")"
}

# Sleep out a near-empty GraphQL budget. The nap does not count toward --timeout
# or --grace: start is moved forward by the same number of seconds.
guard_rate_limit() {
  local now_s reset_epoch wait_for
  if [ -z "$LAST_REMAINING" ]; then
    read_rate_limit
  fi
  if [ "$LAST_REMAINING" -ge "$RATE_FLOOR" ]; then
    return 0
  fi
  now_s=$(now)
  reset_epoch="$(epoch_of "$LAST_RESET")" || die "could not parse rate limit reset ${LAST_RESET}"
  # Two spare seconds so we don't wake in the last tick of the old window.
  wait_for=$((reset_epoch - now_s + 2))
  if [ "$wait_for" -lt 1 ]; then
    echo "pr-wait: graphql rate limit low (${LAST_REMAINING} points remaining, floor ${RATE_FLOOR}) but reset ${LAST_RESET} has passed; continuing"
    LAST_REMAINING=$RATE_FLOOR
    return 0
  fi
  echo "pr-wait: graphql rate limit low (${LAST_REMAINING} points remaining, floor ${RATE_FLOOR}); sleeping ${wait_for}s until ${LAST_RESET}"
  sleep "$wait_for"
  start=$((start + wait_for))
  LAST_REMAINING=""
  LAST_RESET=""
  read_rate_limit
  if [ "$LAST_REMAINING" -lt "$RATE_FLOOR" ]; then
    die "graphql rate limit still ${LAST_REMAINING} after waiting for reset (floor ${RATE_FLOOR})"
  fi
}

# A page that still has more rows must carry an endCursor. Otherwise the
# digest would be the first page only, which is not a readiness result.
cursor_or_die() {
  local more="$1" cursor="$2" label="$3"
  if [ "$more" = true ] && { [ -z "$cursor" ] || [ "$cursor" = null ]; }; then
    die "${label} page is truncated and has no endCursor; refusing a partial digest"
  fi
  if [ -z "$cursor" ] || [ "$cursor" = null ]; then
    printf '%s' ""
  else
    printf '%s' "$cursor"
  fi
}

# Check runs are deduped only within the same name and stable identity.
# Identity is the workflow database id, else its resourcePath, else the app
# database id or slug. Workflow.path no longer exists on the GitHub GraphQL
# schema; resourcePath is the field that still identifies that workflow.
# The display name is only a fallback when the API omitted those, because
# two workflow files can share a name. A later success
# drops an older cancelled run of that same check. Commit statuses are never
# folded into a check run, even when the context string matches the check
# name. A completed conclusion other than success, neutral or skipped is a
# failure (including stale).
count_failed() {
  jq '
    def passing: IN("success", "neutral", "skipped");
    def newest_passing_only:
      group_by([.name, (.group // "")])
      | map(
          sort_by(if (.id | type) == "number" then .id else 0 end) as $runs
          | if ($runs | length) < 2 then $runs
            else
              ($runs[-1]) as $latest
              | if $latest.status == "completed" and (($latest.conclusion // "") | passing) then
                  [$latest]
                else $runs end
            end
        )
      | flatten;
    (map(select(.kind == "status")) + (map(select(.kind != "status")) | newest_passing_only))
    | map(select(
        .status == "completed"
        and (((.conclusion // "") | passing) | not)
      ))
    | length
  '
}

# Concatenate two JSON arrays via files. A single --argjson value over 128KiB
# is rejected by the kernel, which would otherwise drop a page and still look
# like a successful digest.
append_json_file() {
  local dest="$1" piece="$2" next part
  next="$(mktemp)" || die "mktemp failed"
  part="$(mktemp)" || die "mktemp failed"
  printf '%s' "$piece" >"$part"
  if ! jq -s '.[0] + .[1]' "$dest" "$part" >"$next"; then
    rm -f "$next" "$part"
    die "could not accumulate poll page"
  fi
  mv "$next" "$dest"
  rm -f "$part"
}

THREAD_COMMENT_QUERY=$(cat <<'EOF'
query($id:ID!, $after:String) {
  rateLimit { remaining resetAt cost }
  node(id:$id) {
    ... on PullRequestReviewThread {
      comments(first:100, after:$after) {
        pageInfo { hasNextPage endCursor }
        nodes { author { login } body }
      }
    }
  }
}
EOF
)

# Follow comment cursors on any thread whose first page was incomplete.
page_thread_comments() {
  local file="$1" id cursor raw more new_cursor nodes next part n more_json
  if jq -e 'any(.[]; .comments_more == true and ((.id // "") == ""))' "$file" >/dev/null; then
    die "review thread comments are truncated and the thread has no id; refusing a partial digest"
  fi
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    n=0
    while :; do
      more="$(jq -r --arg id "$id" '.[] | select(.id == $id) | .comments_more' "$file")"
      [ "$more" = true ] || break
      n=$((n + 1))
      if [ "$n" -gt 50 ]; then
        die "review thread ${id} still truncated after 50 comment pages; refusing a partial digest"
      fi
      cursor="$(jq -r --arg id "$id" '.[] | select(.id == $id) | .comments_cursor // empty' "$file")"
      if [ -z "$cursor" ] || [ "$cursor" = null ]; then
        die "review thread comments are truncated and have no endCursor; refusing a partial digest"
      fi
      guard_rate_limit
      raw="$(gh_try "thread comments" api graphql -f query="$THREAD_COMMENT_QUERY" -f id="$id" -f after="$cursor")"
      if jq -e '(.errors // []) | length > 0' >/dev/null <<<"$raw"; then
        die "thread comments failed: $(jq -r '[(.errors // [])[].message] | join("; ")' <<<"$raw")"
      fi
      if ! jq -e '.data.node.comments != null' >/dev/null <<<"$raw"; then
        die "thread comments returned no thread ${id}"
      fi
      note_rate_limit \
        "$(jq -r '.data.rateLimit.remaining // empty' <<<"$raw")" \
        "$(jq -r '.data.rateLimit.resetAt // empty' <<<"$raw")"
      nodes="$(jq -c '[.data.node.comments.nodes[]? | {body:(.body // ""), author:{login:(.author.login // "unknown")}}]' <<<"$raw")" \
        || die "could not read thread comments"
      more="$(jq -r '.data.node.comments.pageInfo.hasNextPage' <<<"$raw")"
      new_cursor="$(jq -r '.data.node.comments.pageInfo.endCursor // empty' <<<"$raw")"
      if [ "$more" = true ] && { [ -z "$new_cursor" ] || [ "$new_cursor" = null ]; }; then
        die "review thread comments are truncated and have no endCursor; refusing a partial digest"
      fi
      if [ "$more" = true ]; then more_json=true; else more_json=false; fi
      next="$(mktemp)" || die "mktemp failed"
      part="$(mktemp)" || die "mktemp failed"
      printf '%s' "$nodes" >"$part"
      if ! jq --arg id "$id" --arg cursor "$new_cursor" --argjson more "$more_json" --slurpfile extra "$part" '
        map(if .id == $id then
          .comments.nodes += $extra[0]
          | .comments_more = $more
          | .comments_cursor = $cursor
        else . end)
      ' "$file" >"$next"; then
        rm -f "$next" "$part"
        die "could not accumulate thread comments"
      fi
      mv "$next" "$file"
      rm -f "$part"
    done
  done < <(jq -r '.[] | select(.comments_more == true) | .id' "$file")
}

# A URL carries its own owner, name and number, so it needs no extra request.
# --repo wins when both are present. A branch name (or no argument) is resolved
# once, up front, not on every poll.
case "$PR" in
  http://github.com/*|https://github.com/*|http://www.github.com/*|https://www.github.com/*)
    pr_path="${PR%%\?*}"
    pr_path="${pr_path%%#*}"
    if [[ "$pr_path" =~ github\.com/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
      if [ "$REPO_EXPLICIT" -eq 0 ]; then
        REPO="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
      fi
      PR="${BASH_REMATCH[3]}"
    fi
    ;;
esac

if [ -z "$REPO" ]; then
  REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" || true
fi
[ -n "$REPO" ] || die "not in a GitHub repo; pass --repo OWNER/NAME"

if [[ ! "$PR" =~ ^[0-9]+$ ]]; then
  # `gh pr view --repo` with no selector is a usage error. Pass the branch.
  if [ -z "$PR" ]; then
    PR="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    if [ -z "$PR" ] || [ "$PR" = "HEAD" ]; then
      die "no pull request given and the current branch could not be resolved; pass a PR number, URL, or branch"
    fi
  fi
  meta="$(gh_try "pr view" pr view "$PR" --repo "$REPO" --json number)"
  if jq -e '(.errors // []) | length > 0' >/dev/null <<<"$meta"; then
    die "pr view failed: $(jq -r '[(.errors // [])[].message] | join("; ")' <<<"$meta")"
  fi
  PR="$(jq -r '.number // empty' <<<"$meta")"
  [[ "$PR" =~ ^[0-9]+$ ]] || die "could not resolve a pull request number"
fi

owner="${REPO%%/*}"
repo_name="${REPO#*/}"
if [ -z "$owner" ] || [ "$owner" = "$REPO" ] || [ -z "$repo_name" ]; then
  die "repo must be OWNER/NAME (got '${REPO}')"
fi

banner_done=0
checks='[]'
reviews='[]'
threads='[]'
comments='[]'
mergeable="UNKNOWN"
merge_state="UNKNOWN"
number="$PR"
url=""
base=""
state=""
sha=""
total=0
pending=0
start=$(now)
last_sha=""
stable_since=""
sig_prev=""

# Page every connection to completion. Returns 10 if the head moves mid-page
# so the caller can retry. Globals checks/reviews/threads/comments/sha/… are
# updated only after the full snapshot is in hand.
fetch_snapshot() {
  local contexts_after="" reviews_after="" threads_after="" comments_after=""
  local page=0 raw parsed piece
  local work checks_file reviews_file threads_file comments_file
  local snap_url="" snap_base="" snap_state="" snap_sha="" snap_commit=""
  local snap_mergeable="" snap_merge_state=""
  local more_c more_r more_t more_m cur page_sha
  local -a args
  work="$(mktemp -d)" || die "mktemp failed"
  PR_WAIT_WORK="$work"
  checks_file="$work/checks"
  reviews_file="$work/reviews"
  threads_file="$work/threads"
  comments_file="$work/comments"
  printf '%s' '[]' >"$checks_file"
  printf '%s' '[]' >"$reviews_file"
  printf '%s' '[]' >"$threads_file"
  printf '%s' '[]' >"$comments_file"
  while :; do
    page=$((page + 1))
    if [ "$page" -gt 50 ]; then
      die "poll still truncated after 50 pages; refusing a partial digest"
    fi
    guard_rate_limit
    args=(api graphql -f query="$POLL_QUERY" -f owner="$owner" -f name="$repo_name" -F number="$number")
    if [ -n "$contexts_after" ]; then args+=(-f contextsAfter="$contexts_after"); else args+=(-F contextsAfter=null); fi
    if [ -n "$reviews_after" ]; then args+=(-f reviewsAfter="$reviews_after"); else args+=(-F reviewsAfter=null); fi
    if [ -n "$threads_after" ]; then args+=(-f threadsAfter="$threads_after"); else args+=(-F threadsAfter=null); fi
    if [ -n "$comments_after" ]; then args+=(-f commentsAfter="$comments_after"); else args+=(-F commentsAfter=null); fi
    raw="$(gh_try "poll" "${args[@]}")"
    if jq -e '(.errors // []) | length > 0' >/dev/null <<<"$raw"; then
      die "poll failed: $(jq -r '[(.errors // [])[].message] | join("; ")' <<<"$raw")"
    fi
    if ! jq -e '.data.repository.pullRequest != null' >/dev/null <<<"$raw"; then
      die "poll returned no pull request ${number} in ${REPO}"
    fi
    parsed="$(jq -c "$PARSE_JQ" <<<"$raw")" || die "could not parse poll response"
    note_rate_limit "$(jq -r '.remaining // empty' <<<"$parsed")" "$(jq -r '.resetAt // empty' <<<"$parsed")"

    page_sha="$(jq -r '.sha // empty' <<<"$parsed")"
    if [ -z "$snap_sha" ]; then
      snap_url="$(jq -r '.url // empty' <<<"$parsed")"
      snap_base="$(jq -r '.base // empty' <<<"$parsed")"
      snap_state="$(jq -r '.state // empty' <<<"$parsed")"
      snap_sha="$page_sha"
      snap_commit="$(jq -r '.commit // empty' <<<"$parsed")"
      snap_mergeable="$(jq -r '.mergeable' <<<"$parsed")"
      snap_merge_state="$(jq -r '.merge_state' <<<"$parsed")"
      if [ -z "$snap_url" ] || [ -z "$snap_sha" ] || [ -z "$snap_state" ]; then
        die "poll response missing pull request fields"
      fi
    elif [ "$page_sha" != "$snap_sha" ]; then
      echo "pr-wait: head changed while paging (${snap_sha} -> ${page_sha}); retrying the poll" >&2
      rm -rf "$work"
      PR_WAIT_WORK=""
      return 10
    fi

    piece="$(jq -c '.checks' <<<"$parsed")" || die "could not read checks from poll page"
    append_json_file "$checks_file" "$piece"
    piece="$(jq -c '.reviews' <<<"$parsed")" || die "could not read reviews from poll page"
    append_json_file "$reviews_file" "$piece"
    piece="$(jq -c '.threads' <<<"$parsed")" || die "could not read review threads from poll page"
    append_json_file "$threads_file" "$piece"
    piece="$(jq -c '.comments' <<<"$parsed")" || die "could not read comments from poll page"
    append_json_file "$comments_file" "$piece"

    more_c="$(jq -r '.checks_more' <<<"$parsed")"
    more_r="$(jq -r '.reviews_more' <<<"$parsed")"
    more_t="$(jq -r '.threads_more' <<<"$parsed")"
    more_m="$(jq -r '.comments_more' <<<"$parsed")"
    # Hold the last cursor after a connection is exhausted so the next page of
    # a sibling connection does not request page 1 again and duplicate rows.
    cur="$(cursor_or_die "$more_c" "$(jq -r '.checks_cursor // empty' <<<"$parsed")" checks)"
    [ -n "$cur" ] && contexts_after="$cur"
    cur="$(cursor_or_die "$more_r" "$(jq -r '.reviews_cursor // empty' <<<"$parsed")" reviews)"
    [ -n "$cur" ] && reviews_after="$cur"
    cur="$(cursor_or_die "$more_t" "$(jq -r '.threads_cursor // empty' <<<"$parsed")" "review threads")"
    [ -n "$cur" ] && threads_after="$cur"
    cur="$(cursor_or_die "$more_m" "$(jq -r '.comments_cursor // empty' <<<"$parsed")" comments)"
    [ -n "$cur" ] && comments_after="$cur"
    if [ "$more_c" != true ] && [ "$more_r" != true ] && [ "$more_t" != true ] && [ "$more_m" != true ]; then
      break
    fi
  done

  page_thread_comments "$threads_file"
  checks="$(cat "$checks_file")" || die "could not read accumulated checks"
  reviews="$(cat "$reviews_file")" || die "could not read accumulated reviews"
  threads="$(cat "$threads_file")" || die "could not read accumulated review threads"
  comments="$(cat "$comments_file")" || die "could not read accumulated comments"
  rm -rf "$work"
  PR_WAIT_WORK=""
  url="$snap_url"
  base="$snap_base"
  state="$snap_state"
  sha="$snap_sha"
  commit_oid="$snap_commit"
  mergeable="$snap_mergeable"
  merge_state="$snap_merge_state"
  return 0
}

while :; do
  fetch_snapshot
  fetch_rc=$?
  if [ "$fetch_rc" -eq 10 ]; then
    continue
  fi
  if [ "$fetch_rc" -ne 0 ]; then
    exit "$fetch_rc"
  fi

  if [ "$banner_done" -eq 0 ]; then
    echo "pr-wait: $url  ($state, base $base)"
    banner_done=1
  fi
  # Checks are read from commits(last:1), which can lag headRefOid after a
  # push. Advertising the newer SHA as head= would let --match-head-commit
  # merge a commit whose checks were never read.
  head_mismatch=0
  if [ -n "$commit_oid" ] && [ "$commit_oid" != "$sha" ]; then
    head_mismatch=1
    echo "pr-wait: head ${sha} differs from the commit that carries checks (${commit_oid}); refusing a clean result for ${sha}" >&2
  fi

  if [ "$sha" != "$last_sha" ]; then
    [ -n "$last_sha" ] && echo "pr-wait: new head $sha — restarting the wait"
    last_sha="$sha"; start=$(now); stable_since=""; sig_prev=""
  fi

  total="$(jq 'length' <<<"$checks")"
  pending="$(jq '[.[] | select(.status != "completed")] | length' <<<"$checks")"
  sig="$(jq -r '[.[] | "\(.id):\(.status)"] | sort | join(",")' <<<"$checks")"
  t=$(now)
  elapsed=$((t - start))
  if [ "$NOWAIT" -eq 1 ]; then break; fi
  if [ "$total" -gt 0 ] && [ "$pending" -eq 0 ] && [ "$head_mismatch" -eq 0 ]; then
    # every listed run is done — but only trust the list once it has stopped changing
    if [ "$sig" != "$sig_prev" ] || [ -z "$stable_since" ]; then stable_since=$t; fi
    if [ $((t - stable_since)) -ge "$SETTLE" ]; then break; fi
  else
    stable_since=""
  fi
  if [ "$total" -eq 0 ] && [ "$elapsed" -ge "$GRACE" ] && [ "$head_mismatch" -eq 0 ]; then
    echo "pr-wait: no check runs registered after ${GRACE}s — nothing to wait for (verify the repo has CI/bots before treating this as green)"; break
  fi
  if [ "$elapsed" -ge "$TIMEOUT" ]; then
    # Settle has not elapsed, but nothing is still running. Emitting the digest
    # is the truthful result; exit 2 would claim those checks are in progress.
    if [ "$total" -gt 0 ] && [ "$pending" -eq 0 ] && [ "$head_mismatch" -eq 0 ]; then
      echo "pr-wait: timed out during settle after ${TIMEOUT}s with all $total check(s) complete; emitting the digest"
      break
    fi
    if [ "$head_mismatch" -eq 1 ]; then
      echo "pr-wait: timed out after ${TIMEOUT}s and head ${sha} still differs from checked commit ${commit_oid}" >&2
      break
    fi
    echo "pr-wait: timed out after ${TIMEOUT}s with $pending/$total check(s) still running"; exit 2
  fi
  sig_prev="$sig"
  if [ "$pending" -gt 0 ] || [ "$total" -eq 0 ]; then
    names="$(jq -r '[.[] | select(.status != "completed") | .name] | join(", ")' <<<"$checks")"
    echo "pr-wait: ${elapsed}s  waiting on $pending/$total: ${names:-(registering)}"
  else
    echo "pr-wait: ${elapsed}s  all $total run(s) complete — settling ($((t - stable_since))/${SETTLE}s)"
  fi
  sleep "$INTERVAL"
done

# head= is the commit the checks were read from. When that is not the PR
# head, the snapshot is not a merge precondition.
checked="$sha"
if [ -n "$commit_oid" ]; then
  checked="$commit_oid"
fi

echo
echo "== CHECKS ($checked)"
jq -r '.[] | "\(.conclusion // .status)\t\(.name)\t\(.output.title // "")"' <<<"$checks" | sort | column -t -s $'\t' 2>/dev/null \
  || jq -r '.[] | "\(.conclusion // .status)\t\(.name)"' <<<"$checks"
failed="$(count_failed <<<"$checks")"

echo
echo "== REVIEWS"
jq -r '.[] | "\(.submitted_at) \(.user.login) \(.state)\n    \((.body // "") | gsub("\r";"") | .[0:600] | gsub("\n";"\n    "))"' <<<"$reviews" \
  || die "could not format reviews"
[ "$(jq 'length' <<<"$reviews")" -gt 0 ] || echo "(none)"

echo
echo "== REVIEW THREADS (unresolved first)"
jq -r 'sort_by(.isResolved) | .[] | "--- [\(if .isResolved then "resolved" else "OPEN" end)\(if .isOutdated then ", outdated" else "" end)] \(.path):\(.line // "?")\n" + ([.comments.nodes[] | "  \(.author.login): \(.body | gsub("\r";"") | .[0:900] | gsub("\n";"\n    "))"] | join("\n"))' <<<"$threads" \
  || die "could not format review threads"
[ "$(jq 'length' <<<"$threads")" -gt 0 ] || echo "(none)"
unresolved="$(jq '[.[] | select(.isResolved | not)] | length' <<<"$threads")"

echo
echo "== COMMENTS"
jq -r '.[] | "--- \(.created_at) \(.user.login)\n  \(.body | gsub("\r";"") | .[0:900] | gsub("\n";"\n  "))"' <<<"$comments" \
  || die "could not format comments"
[ "$(jq 'length' <<<"$comments")" -gt 0 ] || echo "(none)"

echo
echo "SUMMARY pr=$number head=$checked checks_total=$total checks_pending=$pending checks_failed=$failed unresolved_threads=$unresolved comments=$(jq 'length' <<<"$comments") state=$state mergeable=$mergeable merge_state=$merge_state truncated=0"
# Exit 0 is only a finished green head. A --no-wait snapshot can still have
# queued or in-progress checks; those are exit 2 with the digest printed.
# A digest whose checks belong to an older commit than the PR head is also
# exit 2, and head= names that older commit so merge cannot pin the new one.
if [ "$head_mismatch" -eq 1 ]; then
  exit 2
fi
if [ "$failed" -gt 0 ]; then
  exit 1
fi
if [ "$pending" -gt 0 ]; then
  exit 2
fi
exit 0
