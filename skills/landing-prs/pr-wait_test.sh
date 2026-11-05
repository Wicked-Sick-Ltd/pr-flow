#!/usr/bin/env bash
# Regression tests for pr-wait.sh readiness rules. Uses a fake gh/git, no network.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$ROOT/pr-wait.sh"
PASS=0
FAIL=0

fail() {
  echo "FAIL: $*" >&2
  FAIL=$((FAIL + 1))
}

ok() {
  echo "ok: $*"
  PASS=$((PASS + 1))
}

envelope() {
  local checks="$1" threads="$2" checks_more="$3" checks_cursor="$4" threads_more="$5" threads_cursor="$6"
  jq -cn \
    --argjson checks "$checks" \
    --argjson threads "$threads" \
    --argjson checks_more "$checks_more" \
    --arg checks_cursor "$checks_cursor" \
    --argjson threads_more "$threads_more" \
    --arg threads_cursor "$threads_cursor" \
    '{
      data: {
        rateLimit: {remaining: 4000, resetAt: "2099-01-01T00:00:00Z", cost: 1},
        repository: {
          pullRequest: {
            number: 4,
            url: "https://github.com/acme/widgets/pull/4",
            state: "OPEN",
            mergeable: "MERGEABLE",
            mergeStateStatus: "CLEAN",
            headRefOid: "abc123",
            headRefName: "feature",
            baseRefName: "main",
            commits: {nodes: [{commit: {oid: "abc123", statusCheckRollup: {contexts: {
              pageInfo: {hasNextPage: $checks_more, endCursor: (if $checks_cursor == "" then null else $checks_cursor end)},
              nodes: $checks
            }}}}]},
            reviews: {pageInfo: {hasNextPage: false, endCursor: null}, nodes: []},
            reviewThreads: {pageInfo: {
              hasNextPage: $threads_more,
              endCursor: (if $threads_cursor == "" then null else $threads_cursor end)
            }, nodes: $threads},
            comments: {pageInfo: {hasNextPage: false, endCursor: null}, nodes: []}
          }
        }
      }
    }'
}

check_run() {
  jq -cn --argjson id "$1" --arg name "$2" --arg status "$3" --arg conclusion "$4" --arg workflow "${5:-}" \
    '{__typename:"CheckRun", databaseId:$id, name:$name, status:$status, conclusion:(if $conclusion == "" then null else $conclusion end), title:"",
      checkSuite:{app:null, workflowRun:(if $workflow == "" then null else {workflow:{name:$workflow}} end)}}'
}

thread() {
  jq -cn --argjson resolved "$1" --arg path "$2" \
    '{isResolved:$resolved, isOutdated:false, path:$path, line:1, comments:{nodes:[{author:{login:"reviewer"}, body:"note"}]}}'
}

setup_bin() {
  local dir="$1"
  mkdir -p "$dir"
  cat >"$dir/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh:$*" >>"${MOCK_LOG:?}"
if [[ "$1" == "pr" && "$2" == "view" ]]; then
  if [[ "$3" == "--repo" || "$3" == "-R" ]]; then
    echo "argument required when using the --repo flag" >&2
    exit 1
  fi
  printf '%s\n' '{"number":4}'
  exit 0
fi
if [[ "$*" == *"node(id:"* ]]; then
  cat "$MOCK_FIXTURE/thread-comments-page.json"
  exit 0
fi
if [[ "$*" != *"pullRequest"* ]]; then
  printf '%s\n' '{"data":{"rateLimit":{"remaining":4000,"resetAt":"2099-01-01T00:00:00Z"}}}'
  exit 0
fi
mode="${MOCK_MODE:?}"
page=1
if [[ "$*" == *"contextsAfter="* && "$*" != *"contextsAfter=null"* ]]; then
  page=2
fi
if [[ "$*" == *"threadsAfter="* && "$*" != *"threadsAfter=null"* ]]; then
  page=2
fi
case "$mode:$page" in
  passing:1) cat "$MOCK_FIXTURE/passing.json" ;;
  stale:1) cat "$MOCK_FIXTURE/stale.json" ;;
  blank:1) cat "$MOCK_FIXTURE/blank.json" ;;
  cancelled-success:1) cat "$MOCK_FIXTURE/cancelled-success.json" ;;
  paginate-checks:1) cat "$MOCK_FIXTURE/checks-page1.json" ;;
  paginate-checks:2) cat "$MOCK_FIXTURE/checks-page2.json" ;;
  paginate-threads:1) cat "$MOCK_FIXTURE/threads-page1.json" ;;
  paginate-threads:2) cat "$MOCK_FIXTURE/threads-page2.json" ;;
  missing-cursor:1) cat "$MOCK_FIXTURE/missing-cursor.json" ;;
  settle:1) cat "$MOCK_FIXTURE/passing.json" ;;
  pending:1) cat "$MOCK_FIXTURE/pending.json" ;;
  mixed-status:1) cat "$MOCK_FIXTURE/mixed-status.json" ;;
  workflows:1) cat "$MOCK_FIXTURE/workflows.json" ;;
  thread-comments:1) cat "$MOCK_FIXTURE/thread-comments.json" ;;
  thread-cursor:1) cat "$MOCK_FIXTURE/thread-cursor.json" ;;
  large-reviews:1) cat "$MOCK_FIXTURE/large-reviews.json" ;;
  *) echo "unexpected mock mode $mode page $page" >&2; exit 1 ;;
esac
EOF
  cat >"$dir/git" <<'EOF'
#!/usr/bin/env bash
echo "git:$*" >>"${MOCK_LOG:?}"
if [[ "$1" == "rev-parse" && "$2" == "--abbrev-ref" ]]; then
  printf '%s\n' "${MOCK_BRANCH:-HEAD}"
  exit 0
fi
echo "unexpected git $*" >&2
exit 1
EOF
  chmod 755 "$dir/gh" "$dir/git"
}

run_wait() {
  local log="$1"
  shift
  MOCK_LOG="$log" PATH="$BIN:/usr/bin:/bin" PR_WAIT_RETRY_SLEEP=0 \
    bash "$SCRIPT" "$@" >"$log.out" 2>"$log.err"
}

assert_summary() {
  local name="$1" out="$2" code="$3" want_code="$4" pattern="$5"
  if [ "$code" -ne "$want_code" ]; then
    fail "$name exit $code want $want_code"
    sed 's/^/  /' "$out" "$out.err" >&2
    return
  fi
  if ! grep -q "$pattern" "$out"; then
    fail "$name missing [$pattern]"
    sed 's/^/  /' "$out" >&2
    return
  fi
  ok "$name"
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"
FIX="$TMP/fix"
mkdir -p "$FIX"
setup_bin "$BIN"
export MOCK_FIXTURE="$FIX"

early="$(check_run 1 early COMPLETED SUCCESS)"
neutral="$(check_run 2 lint COMPLETED NEUTRAL)"
skipped="$(check_run 3 skip COMPLETED SKIPPED)"
envelope "[$early,$neutral,$skipped]" '[]' false "" false "" >"$FIX/passing.json"

stale="$(check_run 1 ci COMPLETED STALE)"
action="$(check_run 2 gate COMPLETED ACTION_REQUIRED)"
startup="$(check_run 3 boot COMPLETED STARTUP_FAILURE)"
envelope "[$stale,$action,$startup]" '[]' false "" false "" >"$FIX/stale.json"

blank="$(check_run 1 ci COMPLETED "")"
envelope "[$blank]" '[]' false "" false "" >"$FIX/blank.json"

cancelled="$(check_run 10 ci COMPLETED CANCELLED)"
later="$(check_run 11 ci COMPLETED SUCCESS)"
envelope "[$cancelled,$later]" '[]' false "" false "" >"$FIX/cancelled-success.json"

page1="$(check_run 1 early COMPLETED SUCCESS)"
envelope "[$page1]" '[]' true "c1" false "" >"$FIX/checks-page1.json"
page2="$(check_run 2 late COMPLETED FAILURE)"
envelope "[$page2]" '[]' false "c2" false "" >"$FIX/checks-page2.json"

resolved="$(thread true README.md)"
open_thread="$(thread false skills/landing-prs/SKILL.md)"
envelope "[$early]" "[$resolved]" false "checks-end" true "t1" >"$FIX/threads-page1.json"
envelope '[]' "[$open_thread]" false "checks-end" false "t2" >"$FIX/threads-page2.json"

envelope "[$early]" '[]' true "" false "" >"$FIX/missing-cursor.json"

pending="$(check_run 1 ci IN_PROGRESS "")"
envelope "[$pending]" '[]' false "" false "" >"$FIX/pending.json"

# 1. success / neutral / skipped are not failures
log="$TMP/passing"
MOCK_MODE=passing run_wait "$log" 4 --repo acme/widgets --no-wait --interval 60
assert_summary "passing conclusions" "$log.out" $? 0 "checks_failed=0 unresolved_threads=0 .* truncated=0"

# 2. stale and other non-passing completed conclusions fail closed
log="$TMP/stale"
MOCK_MODE=stale run_wait "$log" 4 --repo acme/widgets --no-wait --interval 60
assert_summary "stale and other conclusions" "$log.out" $? 1 "checks_failed=3"

# 3. null conclusion is not success/neutral/skipped
log="$TMP/blank"
MOCK_MODE=blank run_wait "$log" 4 --repo acme/widgets --no-wait --interval 60
assert_summary "blank conclusion" "$log.out" $? 1 "checks_failed=1"

# 4. a later success drops the cancelled predecessor of the same name
log="$TMP/cancel"
MOCK_MODE=cancelled-success run_wait "$log" 4 --repo acme/widgets --no-wait --interval 60
assert_summary "cancelled then success" "$log.out" $? 0 "checks_total=2 checks_pending=0 checks_failed=0"

# 5. a failure on page 2 is visible
log="$TMP/pages"
MOCK_MODE=paginate-checks run_wait "$log" 4 --repo acme/widgets --no-wait --interval 60
assert_summary "paginated checks" "$log.out" $? 1 "checks_total=2 checks_pending=0 checks_failed=1"

# 6. an unresolved thread on page 2 is visible, and page 1 checks are not duplicated
log="$TMP/threads"
MOCK_MODE=paginate-threads run_wait "$log" 4 --repo acme/widgets --no-wait --interval 60
assert_summary "paginated threads" "$log.out" $? 0 "checks_total=1 checks_pending=0 checks_failed=0 unresolved_threads=1"

# 7. hasNextPage with no cursor is not reported as a clean digest
log="$TMP/cursor"
MOCK_MODE=missing-cursor run_wait "$log" 4 --repo acme/widgets --no-wait --interval 60
code=$?
if [ "$code" -eq 3 ] && grep -q "no endCursor" "$log.err" && ! grep -q "^SUMMARY " "$log.out"; then
  ok "truncated page fails closed"
else
  fail "truncated page exit=$code"
  sed 's/^/  /' "$log.out" "$log.err" >&2
fi

# 8. timeout during settle still emits the digest
log="$TMP/settle"
MOCK_MODE=settle run_wait "$log" 4 --repo acme/widgets --timeout 0 --settle 10000 --interval 60 --grace 10000
assert_summary "timeout during settle" "$log.out" $? 0 "checks_failed=0"
if ! grep -q "emitting the digest" "$log.out"; then
  fail "timeout during settle did not say it was emitting the digest"
fi

# 9. timeout with a check still running does not pretend to be done
log="$TMP/pending"
MOCK_MODE=pending run_wait "$log" 4 --repo acme/widgets --timeout 0 --settle 10000 --interval 60 --grace 10000
code=$?
if [ "$code" -eq 2 ] && grep -q "still running" "$log.out" && ! grep -q "^SUMMARY " "$log.out"; then
  ok "timeout while pending"
else
  fail "timeout while pending exit=$code"
  sed 's/^/  /' "$log.out" "$log.err" >&2
fi

# 10. no PR argument passes the current branch
log="$TMP/branch"
MOCK_MODE=passing MOCK_BRANCH=feature run_wait "$log" --repo acme/widgets --no-wait --interval 60
assert_summary "current branch" "$log.out" $? 0 "SUMMARY pr=4 "
if ! grep -q "gh:pr view feature --repo acme/widgets --json number" "$log"; then
  fail "current branch was not passed to gh pr view"
  sed 's/^/  /' "$log" >&2
fi
if grep -q "gh:pr view --repo" "$log"; then
  fail "gh pr view was invoked without a selector"
fi

# 11. detached HEAD is a usage error and does not call gh pr view
log="$TMP/detached"
MOCK_MODE=passing MOCK_BRANCH=HEAD run_wait "$log" --repo acme/widgets --no-wait --interval 60
code=$?
if [ "$code" -eq 3 ] && grep -q "current branch could not be resolved" "$log.err" && ! grep -q "gh:pr view" "$log"; then
  ok "detached HEAD"
else
  fail "detached HEAD exit=$code"
  sed 's/^/  /' "$log" "$log.err" >&2
fi

# 12. an explicit branch is used as given
log="$TMP/named"
MOCK_MODE=passing MOCK_BRANCH=should-not-be-read run_wait "$log" some-branch --repo acme/widgets --no-wait --interval 60
assert_summary "explicit branch" "$log.out" $? 0 "SUMMARY pr=4 "
if ! grep -q "gh:pr view some-branch --repo acme/widgets --json number" "$log"; then
  fail "explicit branch was not passed to gh pr view"
  sed 's/^/  /' "$log" >&2
fi
if grep -q "git:rev-parse" "$log"; then
  fail "git was used even though a branch argument was passed"
fi

# 13. a failing commit status is not hidden by a successful check of the same name
status_ci='{"__typename":"StatusContext","context":"ci","state":"FAILURE","description":"legacy"}'
check_ci="$(check_run 9 ci COMPLETED SUCCESS)"
envelope "[$status_ci,$check_ci]" '[]' false "" false "" >"$FIX/mixed-status.json"
log="$TMP/mixed"
MOCK_MODE=mixed-status run_wait "$log" 4 --repo acme/widgets --no-wait --interval 60
assert_summary "status stays beside check" "$log.out" $? 1 "checks_total=2 checks_pending=0 checks_failed=1"

# 14. same check name in two workflows are not the same run
fail_a="$(check_run 1 test COMPLETED FAILURE alpha)"
ok_b="$(check_run 2 test COMPLETED SUCCESS beta)"
envelope "[$fail_a,$ok_b]" '[]' false "" false "" >"$FIX/workflows.json"
log="$TMP/workflows"
MOCK_MODE=workflows run_wait "$log" 4 --repo acme/widgets --no-wait --interval 60
assert_summary "workflows stay separate" "$log.out" $? 1 "checks_total=2 checks_pending=0 checks_failed=1"

# 15. a second page of replies on one thread is part of the digest
thread_more="$(jq -cn '{id:"T1", isResolved:false, isOutdated:false, path:"skills/landing-prs/pr-wait.sh", line:1,
  comments:{pageInfo:{hasNextPage:true, endCursor:"tc1"}, nodes:[{author:{login:"reviewer"}, body:"first-reply"}]}}')"
envelope "[$early]" "[$thread_more]" false "" false "" >"$FIX/thread-comments.json"
jq -cn '{data:{rateLimit:{remaining:4000, resetAt:"2099-01-01T00:00:00Z", cost:1}, node:{comments:{
  pageInfo:{hasNextPage:false, endCursor:"tc2"},
  nodes:[{author:{login:"reviewer"}, body:"second-reply"}]
}}}}' >"$FIX/thread-comments-page.json"
log="$TMP/thread-replies"
MOCK_MODE=thread-comments run_wait "$log" 4 --repo acme/widgets --no-wait --interval 60
code=$?
if [ "$code" -eq 0 ] && grep -q "first-reply" "$log.out" && grep -q "second-reply" "$log.out"; then
  ok "thread comment pages"
else
  fail "thread comment pages exit=$code"
  sed 's/^/  /' "$log.out" "$log.err" >&2
fi

# 16. a thread with more replies and no cursor is not a clean digest
thread_bad="$(jq -cn '{id:"T2", isResolved:false, isOutdated:false, path:"README.md", line:1,
  comments:{pageInfo:{hasNextPage:true, endCursor:null}, nodes:[{author:{login:"reviewer"}, body:"only-page"}]}}')"
envelope "[$early]" "[$thread_bad]" false "" false "" >"$FIX/thread-cursor.json"
log="$TMP/thread-cursor"
MOCK_MODE=thread-cursor run_wait "$log" 4 --repo acme/widgets --no-wait --interval 60
code=$?
if [ "$code" -eq 3 ] && grep -q "no endCursor" "$log.err" && ! grep -q "^SUMMARY " "$log.out"; then
  ok "truncated thread comments fail closed"
else
  fail "truncated thread comments exit=$code"
  sed 's/^/  /' "$log.out" "$log.err" >&2
fi

# 17. a review page larger than one kernel argument is still in the digest
python3 - <<PY
import json
body = "LARGE_REVIEW_TOKEN " + ("x" * 2000)
reviews = [{
    "submittedAt": "2026-01-01T00:00:00Z",
    "state": "COMMENTED",
    "body": body,
    "author": {"login": "reviewer"},
} for _ in range(80)]
early = json.loads('''$early''')
doc = {
  "data": {
    "rateLimit": {"remaining": 4000, "resetAt": "2099-01-01T00:00:00Z", "cost": 1},
    "repository": {"pullRequest": {
      "number": 4,
      "url": "https://github.com/acme/widgets/pull/4",
      "state": "OPEN",
      "mergeable": "MERGEABLE",
      "mergeStateStatus": "CLEAN",
      "headRefOid": "abc123",
      "headRefName": "feature",
      "baseRefName": "main",
      "commits": {"nodes": [{"commit": {"oid": "abc123", "statusCheckRollup": {"contexts": {
        "pageInfo": {"hasNextPage": False, "endCursor": None},
        "nodes": [early],
      }}}}]} ,
      "reviews": {"pageInfo": {"hasNextPage": False, "endCursor": None}, "nodes": reviews},
      "reviewThreads": {"pageInfo": {"hasNextPage": False, "endCursor": None}, "nodes": []},
      "comments": {"pageInfo": {"hasNextPage": False, "endCursor": None}, "nodes": []},
    }},
  }
}
with open("$FIX/large-reviews.json", "w") as f:
    json.dump(doc, f)
PY
log="$TMP/large"
MOCK_MODE=large-reviews run_wait "$log" 4 --repo acme/widgets --no-wait --interval 60
code=$?
count="$(grep -c LARGE_REVIEW_TOKEN "$log.out" || true)"
if [ "$code" -eq 0 ] && [ "$count" -eq 80 ]; then
  ok "large review page kept"
else
  fail "large review page exit=$code count=$count"
  tail -n 20 "$log.err" >&2
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
