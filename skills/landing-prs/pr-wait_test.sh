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
  jq -cn --argjson id "$1" --arg name "$2" --arg status "$3" --arg conclusion "$4" \
    --arg workflow "${5:-}" --arg wf_id "${6:-}" --arg app "${7:-}" --arg resource_path "${8:-}" \
    '{__typename:"CheckRun", databaseId:$id, name:$name, status:$status, conclusion:(if $conclusion == "" then null else $conclusion end), title:"",
      checkSuite:{
        app:(if $app == "" then null else {name:$app, slug:$app, databaseId:null} end),
        workflowRun:(if ($workflow == "" and $wf_id == "" and $resource_path == "") then null else {workflow:{
          name:(if $workflow == "" then null else $workflow end),
          resourcePath:(if $resource_path == "" then null else $resource_path end),
          databaseId:(if $wf_id == "" then null else ($wf_id | tonumber) end)
        }} end)
      }}'
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
  if [[ "${MOCK_VIEW_DOWN:-0}" == 1 ]]; then
    echo "HTTP 502" >&2
    exit 1
  fi
  if [[ "$3" == "--repo" || "$3" == "-R" ]]; then
    echo "argument required when using the --repo flag" >&2
    exit 1
  fi
  printf '%s\n' '{"number":4}'
  exit 0
fi
if [[ "$*" == *"node(id:"* ]]; then
  if [[ "${MOCK_THREAD_DOWN:-0}" == 1 ]]; then
    echo "HTTP 502" >&2
    exit 1
  fi
  cat "$MOCK_FIXTURE/thread-comments-page.json"
  exit 0
fi
if [[ "$*" != *"pullRequest"* ]]; then
  if [[ "${MOCK_RATE_DOWN:-0}" == 1 ]]; then
    echo "HTTP 502" >&2
    exit 1
  fi
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
  same-name:1) cat "$MOCK_FIXTURE/same-name.json" ;;
  same-id:1) cat "$MOCK_FIXTURE/same-id.json" ;;
  paths:1) cat "$MOCK_FIXTURE/paths.json" ;;
  apps:1) cat "$MOCK_FIXTURE/apps.json" ;;
  mismatch:1) cat "$MOCK_FIXTURE/mismatch.json" ;;
  thread-comments:1) cat "$MOCK_FIXTURE/thread-comments.json" ;;
  thread-cursor:1) cat "$MOCK_FIXTURE/thread-cursor.json" ;;
  large-reviews:1) cat "$MOCK_FIXTURE/large-reviews.json" ;;
  app-forbidden:1)
    cat "$MOCK_FIXTURE/app-forbidden.json"
    exit 1
    ;;
  empty-group:1) cat "$MOCK_FIXTURE/empty-group.json" ;;
  suite-same:1) cat "$MOCK_FIXTURE/suite-same.json" ;;
  suite-split:1) cat "$MOCK_FIXTURE/suite-split.json" ;;
  poll-down:*)
    echo "HTTP 502" >&2
    exit 1
    ;;
  head-flip:1) cat "$MOCK_FIXTURE/checks-page1.json" ;;
  head-flip:2) cat "$MOCK_FIXTURE/head-flip-page2.json" ;;
  suite-rerun-fail:1) cat "$MOCK_FIXTURE/suite-rerun-fail.json" ;;
  suite-matrix:1) cat "$MOCK_FIXTURE/suite-matrix.json" ;;
  forbid-p2-ok:1|forbid-p2-bad:1) cat "$MOCK_FIXTURE/checks-page1.json" ;;
  forbid-p2-ok:2)
    cat "$MOCK_FIXTURE/app-forbidden-p2.json"
    exit 1
    ;;
  forbid-p2-bad:2)
    cat "$MOCK_FIXTURE/other-error-p2.json"
    exit 1
    ;;
  other-error:1)
    echo "Field 'something' doesn't exist on type 'Workflow'" >&2
    cat "$MOCK_FIXTURE/other-error.json"
    exit 1
    ;;
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

# A fake clock: sleep N advances date +%s by N and logs "sleep:N", so wait-loop
# paths (interval, settle, timeout) run instantly and deterministically.
setup_clock_bin() {
  local dir="$1"
  mkdir -p "$dir"
  cat >"$dir/sleep" <<'EOF'
#!/usr/bin/env bash
echo "sleep:$1" >>"${MOCK_LOG:?}"
now="$(cat "${MOCK_CLOCK:?}")"
echo $((now + ${1%.*})) >"$MOCK_CLOCK"
EOF
  cat >"$dir/date" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "+%s" ]]; then
  cat "${MOCK_CLOCK:?}"
  exit 0
fi
exec /bin/date "$@"
EOF
  chmod 755 "$dir/sleep" "$dir/date"
}

run_wait_clock() {
  local log="$1"
  shift
  echo 1000 >"$log.clock"
  MOCK_LOG="$log" MOCK_CLOCK="$log.clock" PATH="$CLOCK_BIN:$BIN:/usr/bin:/bin" PR_WAIT_RETRY_SLEEP=0 \
    bash "$SCRIPT" "$@" >"$log.out" 2>"$log.err"
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
CLOCK_BIN="$TMP/clock"
setup_clock_bin "$CLOCK_BIN"
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
assert_summary "passing conclusions" "$log.out" $? 0 "head=abc123 .* checks_failed=0 unresolved_threads=0 .* truncated=0"

# 2. stale and other non-passing completed conclusions fail closed
log="$TMP/stale"
MOCK_MODE=stale run_wait "$log" 4 --repo acme/widgets --no-wait --interval 60
assert_summary "stale and other conclusions" "$log.out" $? 1 "checks_failed=3"

# 3. null conclusion is not success/neutral/skipped
log="$TMP/blank"
MOCK_MODE=blank run_wait "$log" 4 --repo acme/widgets --no-wait --interval 60
assert_summary "blank conclusion" "$log.out" $? 1 "checks_failed=1"

# 4. same name with no workflow, app, or suite id is not one check.
# A later success must not hide the cancelled run.
log="$TMP/cancel"
MOCK_MODE=cancelled-success run_wait "$log" 4 --repo acme/widgets --no-wait --interval 60
assert_summary "unidentified cancelled stays a failure" "$log.out" $? 1 "checks_total=2 checks_pending=0 checks_failed=1"

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
polls="$(grep -c 'pullRequest' "$log" || true)"
if [ "$code" -eq 3 ] && grep -q "no endCursor" "$log.err" && ! grep -q "^SUMMARY " "$log.out" \
  && [ "$polls" -eq 1 ] && ! grep -q "after 50 pages" "$log.err"; then
  ok "truncated page fails closed"
else
  fail "truncated page exit=$code"
  sed 's/^/  /' "$log.out" "$log.err" >&2
fi

# 8. timeout during settle still emits the digest, but is not green: a
# reviewer bot can still register inside the settle window, so exit 2.
log="$TMP/settle"
MOCK_MODE=settle run_wait "$log" 4 --repo acme/widgets --timeout 0 --settle 10000 --interval 60 --grace 10000
assert_summary "timeout during settle is exit 2" "$log.out" $? 2 "checks_failed=0"
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

# 14b. two workflow files can share a display name; the database id keeps them apart
same_fail="$(check_run 1 test COMPLETED FAILURE CI 100)"
same_ok="$(check_run 2 test COMPLETED SUCCESS CI 200)"
envelope "[$same_fail,$same_ok]" '[]' false "" false "" >"$FIX/same-name.json"
log="$TMP/same-name"
MOCK_MODE=same-name run_wait "$log" 4 --repo acme/widgets --no-wait --interval 60
assert_summary "workflow ids stay separate" "$log.out" $? 1 "checks_total=2 checks_pending=0 checks_failed=1"

# 14c. the same workflow id is not proof of a rerun: two matrix jobs (or two
# pushes) share it. Without a shared check suite the cancelled run stays.
rerun_cancel="$(check_run 10 test COMPLETED CANCELLED CI 100)"
rerun_ok="$(check_run 11 test COMPLETED SUCCESS CI 100)"
envelope "[$rerun_cancel,$rerun_ok]" '[]' false "" false "" >"$FIX/same-id.json"
log="$TMP/same-id"
MOCK_MODE=same-id run_wait "$log" 4 --repo acme/widgets --no-wait --interval 60
assert_summary "same workflow id without a suite keeps the failure" "$log.out" $? 1 "checks_total=2 checks_pending=0 checks_failed=1"

# 14d. resourcePath separates workflow files when the API omits the database id.
# The fixture matches the current Workflow selection: databaseId, name,
# resourcePath. It does not include the removed path field.
path_fail="$(check_run 1 test COMPLETED FAILURE CI "" "" /acme/widgets/actions/workflows/ci.yml)"
path_ok="$(check_run 2 test COMPLETED SUCCESS CI "" "" /acme/widgets/actions/workflows/lint.yml)"
envelope "[$path_fail,$path_ok]" '[]' false "" false "" >"$FIX/paths.json"
if jq -e '
  [.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.contexts.nodes[]
    | .checkSuite.workflowRun.workflow
    | select(has("path") or (has("resourcePath") | not) or ((.resourcePath // "") == ""))
  ] | length == 0
' "$FIX/paths.json" >/dev/null; then
  ok "paths fixture uses resourcePath and omits Workflow.path"
else
  fail "paths fixture uses resourcePath and omits Workflow.path"
fi
log="$TMP/paths"
MOCK_MODE=paths run_wait "$log" 4 --repo acme/widgets --no-wait --interval 60
assert_summary "workflow resourcePaths stay separate" "$log.out" $? 1 "checks_total=2 checks_pending=0 checks_failed=1"

# 14e. non-Actions checks of the same name stay apart by app slug
app_fail="$(check_run 1 scan COMPLETED FAILURE "" "" semgrep)"
app_ok="$(check_run 2 scan COMPLETED SUCCESS "" "" codeql)"
envelope "[$app_fail,$app_ok]" '[]' false "" false "" >"$FIX/apps.json"
log="$TMP/apps"
MOCK_MODE=apps run_wait "$log" 4 --repo acme/widgets --no-wait --interval 60
assert_summary "app identity stays separate" "$log.out" $? 1 "checks_total=2 checks_pending=0 checks_failed=1"

# 14f. --no-wait still prints the digest, and pending checks are not exit 0
log="$TMP/nowait-pending"
MOCK_MODE=pending run_wait "$log" 4 --repo acme/widgets --no-wait --interval 60
assert_summary "no-wait pending is not success" "$log.out" $? 2 "checks_total=1 checks_pending=1 checks_failed=0"

# 14g. a newer PR head than the checked commit is not a clean digest
jq '.data.repository.pullRequest.headRefOid = "newsha"' "$FIX/passing.json" >"$FIX/mismatch.json"
log="$TMP/mismatch"
MOCK_MODE=mismatch run_wait "$log" 4 --repo acme/widgets --no-wait --interval 60
code=$?
if [ "$code" -eq 2 ] && grep -q "SUMMARY pr=4 head=abc123 " "$log.out" && ! grep -q "head=newsha" "$log.out" && grep -q "refusing a clean result" "$log.err"; then
  ok "mismatched head is not a clean digest"
else
  fail "mismatched head exit=$code"
  sed 's/^/  /' "$log.out" "$log.err" >&2
fi

# 14h. timeout does not turn that mismatch into a settle success
log="$TMP/mismatch-timeout"
MOCK_MODE=mismatch run_wait "$log" 4 --repo acme/widgets --timeout 0 --settle 0 --interval 60 --grace 10000
code=$?
if [ "$code" -eq 2 ] && grep -q "SUMMARY pr=4 head=abc123 " "$log.out" && ! grep -q "head=newsha" "$log.out"; then
  ok "timeout keeps a mismatched head unclean"
else
  fail "timeout mismatch exit=$code"
  sed 's/^/  /' "$log.out" "$log.err" >&2
fi

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

# Permission wording is part of the offline suite. The helper tests above stay
# network-free; these checks only read the plugin text.
ROOT_DIR="$(cd "$ROOT/../.." && pwd)"
forbid() {
  local file="$1" needle="$2" label="$3"
  if grep -q -F -- "$needle" "$file"; then
    fail "$label"
  else
    ok "$label"
  fi
}
require_text() {
  local file="$1" needle="$2" label="$3"
  if grep -q -F -- "$needle" "$file"; then
    ok "$label"
  else
    fail "$label"
  fi
}
for skill in "$ROOT_DIR/skills/landing-prs/SKILL.md" "$ROOT_DIR/skills/pr/SKILL.md"; do
  base="$(basename "$(dirname "$skill")")/$(basename "$skill")"
  forbid "$skill" "Craig" "$base has no personal standing-rule attribution"
  forbid "$skill" "running autonomously" "$base does not grant autonomous merge"
  forbid "$skill" "non-Critical" "$base does not treat a non-critical label as merge authority"
done
require_text "$ROOT_DIR/skills/landing-prs/SKILL.md" "Installing the plugin is not authorization." "landing-prs states install is not merge authorization"
require_text "$ROOT_DIR/skills/landing-prs/SKILL.md" "must be ready for review" "landing-prs keeps ready-for-review"
require_text "$ROOT_DIR/skills/landing-prs/SKILL.md" 'Never `--admin` past a refusal.' "landing-prs refuses admin bypass"
require_text "$ROOT_DIR/skills/pr/SKILL.md" "Installing the plugin is not" "pr states install is not merge authorization"
require_text "$ROOT_DIR/skills/pr/SKILL.md" "Never use \`--admin\`." "pr refuses admin bypass"
require_text "$ROOT_DIR/skills/pr/SKILL.md" "Confirm the base branch matches" "pr confirms the base branch before merge"
forbid "$ROOT_DIR/SECURITY.md" "This repository is private." "SECURITY.md does not claim a visibility"
forbid "$ROOT_DIR/SECURITY.md" "that form accepts reports" "SECURITY.md does not claim the GitHub form is already open"
require_text "$ROOT_DIR/SECURITY.md" "hello@wickedsick.com" "SECURITY.md keeps the email channel"
require_text "$ROOT_DIR/SECURITY.md" "does not claim that form is enabled" "SECURITY.md keeps the form conditional"
require_text "$SCRIPT" "workflow { databaseId name resourcePath }" "poll query selects Workflow.resourcePath"
if grep -E 'workflow \{[^}]*\bpath\b' "$SCRIPT" >/dev/null; then
  fail "poll query still selects Workflow.path"
else
  ok "poll query does not select Workflow.path"
fi

# 18. Cursor Bugbot's app lookup returns FORBIDDEN because the cursor org has
# an IP allow list. gh exits 1 and still prints the poll body. That error is
# an unknown app; the digest continues. A different error still fails.
bugbot="$(check_run 4 "Cursor Bugbot" COMPLETED SUCCESS)"
bugbot="$(jq -c '.checkSuite.app = null | .checkSuite.workflowRun = null' <<<"$bugbot")"
app_forbidden_error="$(jq -cn '{
  type: "FORBIDDEN",
  path: ["repository","pullRequest","commits","nodes",0,"commit","statusCheckRollup","contexts","nodes",1,"checkSuite","app"],
  extensions: {saml_failure: false, ip_allow_list_failure: true},
  message: "Although you appear to have the correct authorization credentials, the `cursor` organization has an IP allow list enabled, and your IP address is not permitted to access this resource."
}')"
envelope "[$early,$bugbot]" '[]' false "" false "" \
  | jq --argjson err "$app_forbidden_error" '.errors = [$err, $err]' >"$FIX/app-forbidden.json"
log="$TMP/app-forbidden"
MOCK_MODE=app-forbidden run_wait "$log" 4 --repo acme/widgets --no-wait --interval 60
code=$?
if [ "$code" -eq 0 ] \
  && grep -q "SUMMARY pr=4 head=abc123 .*checks_total=2 checks_pending=0 checks_failed=0" "$log.out" \
  && grep -q "Cursor Bugbot" "$log.out" \
  && grep -q "treating app as unknown" "$log.err"; then
  ok "app lookup IP allow list FORBIDDEN continues"
else
  fail "app lookup IP allow list FORBIDDEN exit=$code"
  sed 's/^/  /' "$log.out" "$log.err" >&2
fi

other_error="$(jq -cn '{
  type: "FORBIDDEN",
  path: ["repository"],
  extensions: {saml_failure: false, ip_allow_list_failure: true},
  message: "Although you appear to have the correct authorization credentials, the `cursor` organization has an IP allow list enabled, and your IP address is not permitted to access this resource."
}')"
envelope "[$early]" '[]' false "" false "" \
  | jq --argjson err "$other_error" '.errors = [$err]' >"$FIX/other-error.json"
log="$TMP/other-error"
MOCK_MODE=other-error run_wait "$log" 4 --repo acme/widgets --no-wait --interval 60
code=$?
if [ "$code" -eq 3 ] && grep -q "failed 3 times" "$log.err" && ! grep -q "^SUMMARY " "$log.out"; then
  ok "other FORBIDDEN still fails the poll"
else
  fail "other FORBIDDEN exit=$code"
  sed 's/^/  /' "$log.out" "$log.err" >&2
fi

# 19. Two checks with the same name and no identity must not hide a failure.
# An empty group is not a shared rerun key.
mask_fail="$(check_run 1 scan COMPLETED FAILURE)"
mask_ok="$(check_run 2 scan COMPLETED SUCCESS)"
envelope "[$mask_fail,$mask_ok]" '[]' false "" false "" >"$FIX/empty-group.json"
log="$TMP/empty-group"
MOCK_MODE=empty-group run_wait "$log" 4 --repo acme/widgets --no-wait --interval 60
assert_summary "empty group does not mask a failure" "$log.out" $? 1 "checks_total=2 checks_pending=0 checks_failed=1"

# 20. A check suite id still groups a rerun when the app lookup is missing,
# and a different suite id keeps a same-named failure.
suite_cancel="$(jq -c '.checkSuite.databaseId = 50 | .checkSuite.app = null | .checkSuite.workflowRun = null' <<<"$(check_run 10 scan COMPLETED CANCELLED)")"
suite_ok="$(jq -c '.checkSuite.databaseId = 50 | .checkSuite.app = null | .checkSuite.workflowRun = null' <<<"$(check_run 11 scan COMPLETED SUCCESS)")"
envelope "[$suite_cancel,$suite_ok]" '[]' false "" false "" >"$FIX/suite-same.json"
log="$TMP/suite-same"
MOCK_MODE=suite-same run_wait "$log" 4 --repo acme/widgets --no-wait --interval 60
assert_summary "same suite id drops cancelled" "$log.out" $? 0 "checks_total=2 checks_pending=0 checks_failed=0"

suite_other="$(jq -c '.checkSuite.databaseId = 60 | .checkSuite.app = null | .checkSuite.workflowRun = null' <<<"$(check_run 2 scan COMPLETED SUCCESS)")"
suite_bad="$(jq -c '.checkSuite.databaseId = 70 | .checkSuite.app = null | .checkSuite.workflowRun = null' <<<"$(check_run 1 scan COMPLETED FAILURE)")"
envelope "[$suite_bad,$suite_other]" '[]' false "" false "" >"$FIX/suite-split.json"
log="$TMP/suite-split"
MOCK_MODE=suite-split run_wait "$log" 4 --repo acme/widgets --no-wait --interval 60
assert_summary "suite ids stay separate" "$log.out" $? 1 "checks_total=2 checks_pending=0 checks_failed=1"

# 21. Same workflow, same name, different check suites: a later success in
# another suite does not hide this suite's failure.
matrix_fail="$(jq -c '.checkSuite.databaseId = 80' <<<"$(check_run 1 test COMPLETED FAILURE CI 100)")"
matrix_ok="$(jq -c '.checkSuite.databaseId = 81' <<<"$(check_run 2 test COMPLETED SUCCESS CI 100)")"
envelope "[$matrix_fail,$matrix_ok]" '[]' false "" false "" >"$FIX/suite-matrix.json"
log="$TMP/suite-matrix"
MOCK_MODE=suite-matrix run_wait "$log" 4 --repo acme/widgets --no-wait --interval 60
assert_summary "same workflow in two suites keeps the failure" "$log.out" $? 1 "checks_total=2 checks_pending=0 checks_failed=1"

# 22. Within one suite the newest run is the result only if it passed: an
# older success never hides a newer failure.
rerun_old_ok="$(jq -c '.checkSuite.databaseId = 90' <<<"$(check_run 1 test COMPLETED SUCCESS CI 100)")"
rerun_new_bad="$(jq -c '.checkSuite.databaseId = 90' <<<"$(check_run 2 test COMPLETED FAILURE CI 100)")"
envelope "[$rerun_old_ok,$rerun_new_bad]" '[]' false "" false "" >"$FIX/suite-rerun-fail.json"
log="$TMP/suite-rerun-fail"
MOCK_MODE=suite-rerun-fail run_wait "$log" 4 --repo acme/widgets --no-wait --interval 60
assert_summary "newer failure in a suite is not hidden" "$log.out" $? 1 "checks_failed=1"

# 23. A die inside $(gh_try ...) must stop the script with that message, not
# fall through to a parse of empty output.
expect_down() {
  local name="$1" log="$2" want="$3" leak="$4" code="$5"
  if [ "$code" -eq 3 ] && grep -q "$want" "$log.err" && ! grep -q -E "$leak" "$log.err" && ! grep -q "^SUMMARY " "$log.out"; then
    ok "$name"
  else
    fail "$name exit=$code"
    sed 's/^/  /' "$log.out" "$log.err" >&2
  fi
}
log="$TMP/rate-down"
MOCK_MODE=passing MOCK_RATE_DOWN=1 run_wait "$log" 4 --repo acme/widgets --no-wait --interval 60
expect_down "rate limit down stops" "$log" "rate limit failed 3 times" "missing remaining|missing resetAt" $?
log="$TMP/poll-down"
MOCK_MODE=poll-down run_wait "$log" 4 --repo acme/widgets --no-wait --interval 60
expect_down "poll down stops" "$log" "poll failed 3 times" "poll returned no pull request|could not parse" $?
log="$TMP/view-down"
MOCK_MODE=passing MOCK_VIEW_DOWN=1 run_wait "$log" feature --repo acme/widgets --no-wait --interval 60
expect_down "pr view down stops" "$log" "pr view failed 3 times" "could not resolve" $?
log="$TMP/thread-down"
MOCK_MODE=thread-comments MOCK_THREAD_DOWN=1 run_wait "$log" 4 --repo acme/widgets --no-wait --interval 60
expect_down "thread comments down stops" "$log" "thread comments failed 3 times" "returned no thread|could not read" $?

# 24. A head mismatch with every listed check complete reports that it is
# waiting for the head, never a settle count from an unset clock.
log="$TMP/mismatch-wait"
MOCK_MODE=mismatch run_wait_clock "$log" 4 --repo acme/widgets --timeout 100 --settle 0 --interval 60 --grace 10000
code=$?
if [ "$code" -eq 2 ] && grep -q "waiting for checks on head newsha" "$log.out" && ! grep -q "settling" "$log.out"; then
  ok "mismatch status line does not use an unset settle clock"
else
  fail "mismatch status line exit=$code"
  sed 's/^/  /' "$log.out" "$log.err" >&2
fi

# 25. A head that moves while paging waits one interval before retrying and
# still honours --timeout; --no-wait gives up after three attempts.
jq '.data.repository.pullRequest.headRefOid = "def456"' "$FIX/checks-page2.json" >"$FIX/head-flip-page2.json"
log="$TMP/head-flip"
MOCK_MODE=head-flip run_wait_clock "$log" 4 --repo acme/widgets --timeout 100 --interval 60 --grace 10000
code=$?
sleeps="$(grep -c '^sleep:60$' "$log" || true)"
if [ "$code" -eq 2 ] && [ "$sleeps" -ge 1 ] && grep -q "head kept changing" "$log.err" && ! grep -q "^SUMMARY " "$log.out"; then
  ok "head change while paging waits the interval and times out"
else
  fail "head change while paging exit=$code sleeps=$sleeps"
  sed 's/^/  /' "$log.out" "$log.err" >&2
fi
log="$TMP/head-flip-nowait"
MOCK_MODE=head-flip run_wait_clock "$log" 4 --repo acme/widgets --no-wait --interval 60
code=$?
polls="$(grep -c 'pullRequest' "$log" || true)"
if [ "$code" -eq 2 ] && [ "$polls" -eq 6 ] && grep -q "3 attempts" "$log.err"; then
  ok "no-wait head change gives up after three attempts"
else
  fail "no-wait head change exit=$code polls=$polls"
  sed 's/^/  /' "$log.out" "$log.err" >&2
fi

# 26. The Bugbot FORBIDDEN on a later page is tolerated and the page-1 check is
# kept once; an unrelated FORBIDDEN on a later page still fails closed.
envelope "[$bugbot]" '[]' false "c2" false "" \
  | jq --argjson err "$app_forbidden_error" '.errors = [$err]' >"$FIX/app-forbidden-p2.json"
envelope "[$bugbot]" '[]' false "c2" false "" \
  | jq --argjson err "$other_error" '.errors = [$err]' >"$FIX/other-error-p2.json"
log="$TMP/forbid-p2-ok"
MOCK_MODE=forbid-p2-ok run_wait "$log" 4 --repo acme/widgets --no-wait --interval 60
assert_summary "page-2 app FORBIDDEN continues" "$log.out" $? 0 "checks_total=2 checks_pending=0 checks_failed=0"
log="$TMP/forbid-p2-bad"
MOCK_MODE=forbid-p2-bad run_wait "$log" 4 --repo acme/widgets --no-wait --interval 60
expect_down "page-2 other FORBIDDEN fails closed" "$log" "poll failed 3 times" "poll returned no pull request|could not parse" $?

fetch_cmd='(set -o pipefail; gh api --method GET -f ref="$ref" repos/Wicked-Sick-Ltd/pr-flow/contents/skills/landing-prs/pr-wait.sh > "$meta") && test "$(jq -r .sha < "$meta")" = "$want"'
require_text "$ROOT_DIR/skills/landing-prs/SKILL.md" "$fetch_cmd" "landing-prs fetch command"
require_text "$ROOT_DIR/README.md" "$fetch_cmd" "README fetch command"
require_text "$ROOT_DIR/CHANGELOG.md" "$fetch_cmd" "CHANGELOG fetch command"
require_text "$ROOT_DIR/skills/landing-prs/SKILL.md" "Do not download" "landing-prs does not fetch over the sibling helper"
require_text "$ROOT_DIR/plugin.json" '"version": "1.1.2"' "plugin.json matches the helper revision"
require_text "$ROOT_DIR/.cursor-plugin/plugin.json" '"version": "1.1.2"' "cursor plugin.json matches"
require_text "$ROOT_DIR/.claude-plugin/plugin.json" '"version": "1.1.2"' "claude plugin.json matches"
require_text "$ROOT_DIR/.codex-plugin/plugin.json" '"version": "1.1.2"' "codex plugin.json matches"
require_text "$ROOT_DIR/skills/landing-prs/SKILL.md" "Wicked-Sick-Ltd/ai-grok-repo" "landing-prs names the old path"
require_text "$ROOT_DIR/README.md" "returns 404" "README says the old path returns 404"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
