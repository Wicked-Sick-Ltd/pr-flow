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

# pr NUMBER REPO LOGIN TOTAL_COMMENTS [COMMENT_BODY ...]
pr() {
  local number="$1" repo="$2" login="$3" total="$4"
  shift 4
  jq -cn --argjson number "$number" --arg repo "$repo" --arg login "$login" \
    --argjson total "$total" '{
      number: $number, title: ("Change " + ($number | tostring)),
      mergedAt: "2026-11-27T10:00:00Z",
      repository: {nameWithOwner: $repo},
      mergedBy: {login: $login},
      mergeCommit: {abbreviatedOid: ("sha" + ($number | tostring))},
      comments: {totalCount: $total, nodes: ($ARGS.positional | map({body: .}))}
    }' --args "$@"
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
page 6 true c1 \
  "$(pr 4 acme/widgets alice 2 'Looks good' "$EXPLICIT")" \
  "$(pr 12 acme/widgets bob 0)" \
  "$(pr 15 acme/widgets bob 73 'an unrelated comment')" \
  >"$TMP/mixed/page-first.json"
page 6 false "" \
  "$(pr 9 other/gadgets alice 1 "$EXPLICIT_COMMA")" \
  "$(pr 7 other/gadgets carol 1 "$TESTS_ONLY")" \
  "$(pr 16 other/gadgets dave 1 'I see this was Merged by someone under a rule.')" \
  >"$TMP/mixed/page-c1.json"

run mixed --owner acme --owner other --date 2026-11-27
[ "$RC" -eq 1 ] && ok "unattributed merges exit 1" || fail "mixed day exit was $RC, want 1: $OUT"
has "SUMMARY date=2026-11-27 owners=acme,other merged=6 attributed=3 unattributed=3" &&
  ok "summary counts both pages" || fail "summary wrong: $OUT"
has "== UNATTRIBUTED (3)" && ok "unattributed heading" || fail "no unattributed heading: $OUT"
has "acme/widgets#12 | Change 12 | merged by bob | sha12 | no attribution comment" &&
  ok "a merge with no comment is listed with who merged it" || fail "#12 line wrong: $OUT"
has "acme/widgets#15 | Change 15 | merged by bob | sha15 | not in the last 50 of 73 comments" &&
  ok "a long thread is reported as unchecked, not as missing" || fail "#15 line wrong: $OUT"
has "other/gadgets#16 | Change 16 | merged by dave | sha16 | no attribution comment" &&
  ok "a comment that only mentions the phrase does not count" || fail "#16 line wrong: $OUT"
has "Claude Code (Fable) | explicit go from the owner (2)" &&
  ok "the parenthesis and comma forms group under one rule" || fail "explicit group wrong: $OUT"
has "Cursor Agent | tests/CI-only self-merge (1)" && ok "second group" || fail "tests-only group wrong: $OUT"
has "  other/gadgets#9 | Change 9 | sha9" && ok "group lists its merges" || fail "group member wrong: $OUT"
[ "$(grep -n -F '== UNATTRIBUTED' <<<"$OUT" | cut -d: -f1)" -lt "$(grep -n -F '== BY AGENT AND RULE' <<<"$OUT" | cut -d: -f1)" ] &&
  ok "unattributed merges come first" || fail "section order wrong: $OUT"
[ "$(wc -l <"$TMP/mixed/log" | tr -d ' ')" -eq 2 ] && ok "two pages, two calls" || fail "call count: $(cat "$TMP/mixed/log")"
grep -qF "q=user:acme user:other is:pr is:merged merged:2026-11-27" "$TMP/mixed/log" &&
  ok "search covers every owner" || fail "search string wrong: $(cat "$TMP/mixed/log")"
sed -n 2p "$TMP/mixed/log" | grep -qF "after=c1" && ok "second call carries the cursor" || fail "no cursor: $(cat "$TMP/mixed/log")"

# --- every merge attributed -------------------------------------------------
mkdir -p "$TMP/clean"
page 1 false "" "$(pr 4 acme/widgets alice 1 "$EXPLICIT")" >"$TMP/clean/page-first.json"
run clean --owner acme --date 2026-11-27
[ "$RC" -eq 0 ] && has "== UNATTRIBUTED (0)" && has "merged=1 attributed=1 unattributed=0" &&
  ok "all attributed exits 0" || fail "clean day: rc=$RC $OUT"

# --- a day with no merges ---------------------------------------------------
mkdir -p "$TMP/empty"
jq -cn '{data: {search: {issueCount: 0, pageInfo: {hasNextPage: false, endCursor: null}, nodes: []}}}' \
  >"$TMP/empty/page-first.json"
run empty --owner acme --date 2026-11-27
[ "$RC" -eq 0 ] && has "merged=0 attributed=0 unattributed=0" && ok "no merges exits 0" || fail "empty day: rc=$RC $OUT"

# --- refusals: a partial answer is never reported as an audit ---------------
mkdir -p "$TMP/toomany"
page 1500 false "" "$(pr 4 acme/widgets alice 1 "$EXPLICIT")" >"$TMP/toomany/page-first.json"
run toomany --owner acme --date 2026-11-27
[ "$RC" -eq 3 ] && has "1000" && ! has "SUMMARY" && ok "more than 1000 results is refused" || fail "toomany: rc=$RC $OUT"

mkdir -p "$TMP/short"
page 5 false "" "$(pr 4 acme/widgets alice 1 "$EXPLICIT")" >"$TMP/short/page-first.json"
run short --owner acme --date 2026-11-27
[ "$RC" -eq 3 ] && ! has "SUMMARY" && ok "fewer results than the count is refused" || fail "short: rc=$RC $OUT"

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
