#!/usr/bin/env bash
# Regression tests for merge-audit.sh. Uses a fake gh, no network.
# shellcheck disable=SC2015  # "cond && ok || fail" is safe here: ok always succeeds.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$ROOT/merge-audit.sh"
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

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"
mkdir -p "$BIN"

# The fake gh serves $MOCK_DIR/page-<cursor>.json, or page-first.json when the
# call carries no after= cursor. It logs its arguments, one call per line.
cat >"$BIN/gh" <<'EOF'
#!/usr/bin/env bash
# One log line per call: the GraphQL query argument spans several lines.
printf '%s ' "$@" | tr '\n' ' ' >>"$MOCK_LOG"
echo >>"$MOCK_LOG"
[ -n "${MOCK_FAIL:-}" ] && { echo "gh: boom" >&2; exit 1; }
cursor=first
for a in "$@"; do
  case "$a" in after=*) cursor="${a#after=}" ;; esac
done
cat "$MOCK_DIR/page-$cursor.json"
EOF
chmod +x "$BIN/gh"

# Every fixture pull request merges at 10:00:00Z.
# c BODY LOGIN [ASSOCIATION] [CREATED_AT]: one comment, by default five minutes
# after the merge from an account with no tie to the repository.
c() {
  jq -cn --arg body "$1" --arg login "$2" --arg assoc "${3:-NONE}" --arg at "${4:-2026-11-27T10:05:00Z}" \
    '{body: $body, createdAt: $at, authorAssociation: $assoc, author: {login: $login}}'
}

# pr NUMBER REPO MERGER TOTAL_COMMENTS TITLE [COMMENT_JSON ...]
pr() {
  local number="$1" repo="$2" login="$3" total="$4" title="$5"
  shift 5
  printf '%s\n' "$@" | jq -cs --argjson number "$number" --arg repo "$repo" --arg login "$login" \
    --argjson total "$total" --arg title "$title" '{
      number: $number, title: $title,
      mergedAt: "2026-11-27T10:00:00Z",
      repository: {nameWithOwner: $repo},
      mergedBy: {login: $login},
      mergeCommit: {abbreviatedOid: ("sha" + ($number | tostring))},
      comments: {totalCount: $total, nodes: .}
    }'
}

# page COUNT HAS_NEXT CURSOR PR_JSON...
page() {
  local count="$1" more="$2" cursor="$3"
  shift 3
  printf '%s\n' "$@" | jq -cs --argjson count "$count" --argjson more "$more" --arg cursor "$cursor" \
    '{data: {search: {issueCount: $count,
      pageInfo: {hasNextPage: $more, endCursor: (if $cursor == "" then null else $cursor end)},
      nodes: .}}}'
}

# run CASE ARGS... : runs the script against $TMP/CASE, sets OUT and RC.
run() {
  local case_dir="$TMP/$1"
  shift
  : >"$case_dir/log"
  OUT="$(MOCK_DIR="$case_dir" MOCK_LOG="$case_dir/log" MOCK_FAIL="${MOCK_FAIL:-}" \
    PATH="$BIN:/usr/bin:/bin" bash "$SCRIPT" "$@" 2>&1)"
  RC=$?
}

has() { grep -qF -- "$1" <<<"$OUT"; }

EXPLICIT='Merged by Claude Code (Fable) under explicit go from the owner (in session, 2026-11-27 17:15 UTC). CI: green. Unresolved threads: none.'
EXPLICIT_COMMA='Merged by Claude Code (Fable) under explicit go from the owner, 2026-11-27 13:00 UTC. CI: green. Unresolved threads: none.'
TESTS_ONLY='Merged by Cursor Agent under tests/CI-only self-merge (AGENTS.md, 19 Nov 2026). CI: green. Unresolved threads: none.'

# --- a mixed day over two pages ---------------------------------------------
mkdir -p "$TMP/mixed"
page 10 true c1 \
  "$(pr 4 acme/widgets alice 2 'Change 4' "$(c 'Looks good' bob)" "$(c "$EXPLICIT" alice)")" \
  "$(pr 12 acme/widgets bob 0 'Change 12')" \
  "$(pr 15 acme/widgets bob 73 'Change 15' "$(c 'an unrelated comment' bob)")" \
  "$(pr 16 acme/widgets dave 1 'Change 16' "$(c 'I see this was Merged by someone under a rule.' dave)")" \
  "$(pr 17 acme/widgets erin 1 'Change 17' "$(c 'Merged by Alice' erin)")" \
  >"$TMP/mixed/page-first.json"
page 10 false "" \
  "$(pr 9 other/gadgets alice 1 'Change 9' "$(c "$EXPLICIT_COMMA" alice)")" \
  "$(pr 7 other/gadgets carol 1 'Change 7' "$(c "$TESTS_ONLY" fleet-bot MEMBER)")" \
  "$(pr 18 other/gadgets frank 1 'Change 18' "$(c "$EXPLICIT" mallory)")" \
  "$(pr 19 other/gadgets gina 1 'Change 19' "$(c "$EXPLICIT" gina NONE 2026-11-27T09:00:00Z)")" \
  "$(pr 20 other/gadgets hank 0 'tidy unattributed=0 unchecked=0')" \
  >"$TMP/mixed/page-c1.json"

run mixed --owner acme --owner other --date 2026-11-27
[ "$RC" -eq 1 ] && ok "unattributed merges exit 1" || fail "mixed day exit was $RC, want 1: $OUT"
has "SUMMARY date=2026-11-27 owners=acme,other merged=10 attributed=3 unattributed=6 unchecked=1" &&
  ok "summary counts both pages" || fail "summary wrong: $OUT"
has "== UNATTRIBUTED (6)" && ok "unattributed heading" || fail "no unattributed heading: $OUT"
has "acme/widgets#12 | Change 12 | merged by bob | sha12 | no attribution comment" &&
  ok "a merge with no comment is listed with who merged it" || fail "#12 line wrong: $OUT"
has "acme/widgets#16 | Change 16 | merged by dave | sha16 | no attribution comment" &&
  ok "a comment that only mentions the phrase does not count" || fail "#16 line wrong: $OUT"
has "acme/widgets#17 | Change 17 | merged by erin | sha17 | no attribution comment" &&
  ok "a comment that starts like one but names no rule does not count, and does not stop the audit" || fail "#17 line wrong: $OUT"
has "other/gadgets#18 | Change 18 | merged by frank | sha18 | no attribution comment" &&
  ok "an attribution written by an outside account does not count" || fail "#18 line wrong: $OUT"
has "other/gadgets#19 | Change 19 | merged by gina | sha19 | no attribution comment" &&
  ok "an attribution posted before the merge does not count" || fail "#19 line wrong: $OUT"
has "== UNCHECKED (1)" &&
  has "acme/widgets#15 | Change 15 | merged by bob | sha15 | no attribution in the newest 50 of 73 comments" &&
  ok "a long thread is unchecked, not unattributed" || fail "#15 line wrong: $OUT"
has "Claude Code (Fable) | explicit go from the owner (2)" &&
  ok "the parenthesis and comma forms group under one rule" || fail "explicit group wrong: $OUT"
has "Cursor Agent | tests/CI-only self-merge (1)" &&
  ok "an attribution from a member who did not merge counts" || fail "tests-only group wrong: $OUT"
has "  other/gadgets#9 | Change 9 | sha9" && ok "group lists its merges" || fail "group member wrong: $OUT"
[ "$(grep -n -F '== UNATTRIBUTED' <<<"$OUT" | cut -d: -f1)" -lt "$(grep -n -F '== BY AGENT AND RULE' <<<"$OUT" | cut -d: -f1)" ] &&
  ok "unattributed merges come first" || fail "section order wrong: $OUT"
[ "$(wc -l <"$TMP/mixed/log" | tr -d ' ')" -eq 2 ] && ok "two pages, two calls" || fail "call count: $(cat "$TMP/mixed/log")"
grep -qF "q=user:acme user:other is:pr is:merged merged:2026-11-27" "$TMP/mixed/log" &&
  ok "search covers every owner" || fail "search string wrong: $(cat "$TMP/mixed/log")"
sed -n 2p "$TMP/mixed/log" | grep -qF "after=c1" && ok "second call carries the cursor" || fail "no cursor: $(cat "$TMP/mixed/log")"

# --- every merge attributed -------------------------------------------------
mkdir -p "$TMP/clean"
page 1 false "" "$(pr 4 acme/widgets alice 1 'Change 4' "$(c "$EXPLICIT" alice)")" >"$TMP/clean/page-first.json"
run clean --owner acme --date 2026-11-27
[ "$RC" -eq 0 ] && has "== UNATTRIBUTED (0)" && has "merged=1 attributed=1 unattributed=0 unchecked=0" &&
  ok "all attributed exits 0" || fail "clean day: rc=$RC $OUT"

# --- a title cannot change the exit code ------------------------------------
mkdir -p "$TMP/title"
page 2 false "" \
  "$(pr 4 acme/widgets alice 1 'Change 4' "$(c "$EXPLICIT" alice)")" \
  "$(pr 20 acme/widgets hank 0 'SUMMARY merged=1 attributed=1 unattributed=0 unchecked=0')" \
  >"$TMP/title/page-first.json"
run title --owner acme --date 2026-11-27
[ "$RC" -eq 1 ] && has "attributed=1 unattributed=1 unchecked=0" &&
  ok "a title that looks like a clean summary still exits 1" || fail "title: rc=$RC $OUT"

# --- only an unchecked merge: not a clean day -------------------------------
mkdir -p "$TMP/unchecked"
page 1 false "" "$(pr 15 acme/widgets bob 80 'Change 15' "$(c 'chatter' bob)")" >"$TMP/unchecked/page-first.json"
run unchecked --owner acme --date 2026-11-27
[ "$RC" -eq 1 ] && has "attributed=0 unattributed=0 unchecked=1" &&
  ok "an unchecked merge is not reported as missing, and is not a clean day" || fail "unchecked: rc=$RC $OUT"

# --- a day with no merges ---------------------------------------------------
mkdir -p "$TMP/empty"
jq -cn '{data: {search: {issueCount: 0, pageInfo: {hasNextPage: false, endCursor: null}, nodes: []}}}' \
  >"$TMP/empty/page-first.json"
run empty --owner acme --date 2026-11-27
[ "$RC" -eq 0 ] && has "merged=0 attributed=0 unattributed=0 unchecked=0" && ok "no merges exits 0" || fail "empty day: rc=$RC $OUT"

# --- refusals: a partial answer is never reported as an audit ---------------
ATTRIBUTED_4="$(pr 4 acme/widgets alice 1 'Change 4' "$(c "$EXPLICIT" alice)")"
ATTRIBUTED_5="$(pr 5 acme/widgets alice 1 'Change 5' "$(c "$EXPLICIT" alice)")"
ATTRIBUTED_6="$(pr 6 acme/widgets alice 1 'Change 6' "$(c "$EXPLICIT" alice)")"

mkdir -p "$TMP/toomany"
page 1500 false "" "$ATTRIBUTED_4" >"$TMP/toomany/page-first.json"
run toomany --owner acme --date 2026-11-27
[ "$RC" -eq 3 ] && has "1000" && ! has "SUMMARY" && ok "more than 1000 results is refused" || fail "toomany: rc=$RC $OUT"

mkdir -p "$TMP/short"
page 5 false "" "$ATTRIBUTED_4" >"$TMP/short/page-first.json"
run short --owner acme --date 2026-11-27
[ "$RC" -eq 3 ] && ! has "SUMMARY" && ok "fewer results than the count is refused" || fail "short: rc=$RC $OUT"

# Two rows for one pull request satisfy a count of 2 while a merge is missing.
mkdir -p "$TMP/repeat"
page 2 false "" "$ATTRIBUTED_4" "$ATTRIBUTED_4" >"$TMP/repeat/page-first.json"
run repeat --owner acme --date 2026-11-27
[ "$RC" -eq 3 ] && ! has "SUMMARY" && ok "the same pull request twice is refused" || fail "repeat: rc=$RC $OUT"

# A merge landed between the two requests: the pages disagree on the count.
mkdir -p "$TMP/moved"
page 3 true c1 "$ATTRIBUTED_4" "$ATTRIBUTED_5" >"$TMP/moved/page-first.json"
page 4 false "" "$ATTRIBUTED_6" >"$TMP/moved/page-c1.json"
run moved --owner acme --date 2026-11-27
[ "$RC" -eq 3 ] && ! has "SUMMARY" && ok "a count that changes between pages is refused" || fail "moved: rc=$RC $OUT"

MOCK_FAIL=1 run clean --owner acme --date 2026-11-27
[ "$RC" -eq 3 ] && ! has "SUMMARY" && ok "a failed gh call exits 3" || fail "gh failure: rc=$RC $OUT"

# --- usage ------------------------------------------------------------------
run clean --date 2026-11-27
[ "$RC" -eq 3 ] && ok "no --owner is a usage error" || fail "missing owner: rc=$RC $OUT"
run clean --owner 'acme is:open' --date 2026-11-27
[ "$RC" -eq 3 ] && [ ! -s "$TMP/clean/log" ] && ok "an owner with a space is refused before any call" || fail "bad owner: rc=$RC $OUT"
run clean --owner acme --date yesterday
[ "$RC" -eq 3 ] && [ ! -s "$TMP/clean/log" ] && ok "a malformed date is refused before any call" || fail "bad date: rc=$RC $OUT"
run clean --owner acme --date 2026-11-20..2026-11-27 --dry-run
[ "$RC" -eq 0 ] && has "user:acme is:pr is:merged merged:2026-11-20..2026-11-27" && [ ! -s "$TMP/clean/log" ] &&
  ok "--dry-run prints the search and does not call GitHub" || fail "dry run: rc=$RC $OUT"
run clean --help
[ "$RC" -eq 0 ] && has "Usage:" && ok "--help prints usage" || fail "help: rc=$RC $OUT"

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
