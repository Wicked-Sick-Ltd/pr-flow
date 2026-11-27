#!/usr/bin/env bash
# HELP-START
# merge-audit.sh — list the pull requests merged on a day across one or more
# GitHub owners, and say which of them carry a merge-attribution comment.
#
# Why a script: GitHub's merge record is the merge log. An agent that forgets
# the attribution comment would forget a separate log line too, so a hand-kept
# log cannot show what is missing from it. A search of what merged can.
#
# Usage:
#   merge-audit.sh --owner OWNER [--owner OWNER ...] [--date DATE] [--dry-run]
#   OWNER is a GitHub user or organisation. DATE is YYYY-MM-DD (UTC) or a range
#   YYYY-MM-DD..YYYY-MM-DD; the default is today in UTC.
#   --dry-run prints the search and does not call GitHub.
#
# Output: the merges with no attribution comment first, each with who merged
# it (a person's own merge needs no comment, and only the reader can tell the
# two apart). Then the attributed merges grouped by agent and rule. Then one
# SUMMARY line.
#
# An attribution comment starts "Merged by <agent> under <rule>". The rule name
# ends at the first " (", "," or full stop. Only the last 50 comments of each
# pull request are read; a longer thread with no match is reported as
# unchecked, not as missing.
#
# Exit codes: 0 every merge is attributed (or nothing merged), 1 at least one
# merge has no attribution comment, 3 usage error or GitHub failure. GitHub
# search returns at most 1000 results: past that the script stops with exit 3,
# because part of a day is not an audit.
#
# Requires bash, an authenticated gh, and jq.
# HELP-END
set -uo pipefail

DEPTH=50 # comments read per pull request, newest first

die() {
  echo "merge-audit: $*" >&2
  exit 3
}

owners=()
date_arg=""
dry_run=0
while [ $# -gt 0 ]; do
  case "$1" in
    --owner)
      [ $# -ge 2 ] || die "--owner needs a value"
      owners+=("$2")
      shift 2
      ;;
    --date)
      [ $# -ge 2 ] || die "--date needs a value"
      date_arg="$2"
      shift 2
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    -h | --help)
      sed -n '/^# HELP-START/,/^# HELP-END/p' "$0" | sed '1d;$d;s/^# \{0,1\}//'
      exit 0
      ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

[ ${#owners[@]} -gt 0 ] || die "at least one --owner is required (see --help)"
[ -n "$date_arg" ] || date_arg="$(date -u +%F)"

# Both values go into the search string, so neither may carry a second qualifier.
date_re='^[0-9]{4}-[0-9]{2}-[0-9]{2}(\.\.[0-9]{4}-[0-9]{2}-[0-9]{2})?$'
owner_re='^[A-Za-z0-9][A-Za-z0-9-]*$'
[[ "$date_arg" =~ $date_re ]] || die "--date must be YYYY-MM-DD or YYYY-MM-DD..YYYY-MM-DD"
q=""
for owner in "${owners[@]}"; do
  [[ "$owner" =~ $owner_re ]] || die "not a GitHub owner name: $owner"
  q+="user:$owner " # user: matches organisations as well; repeated qualifiers are ORed
done
q+="is:pr is:merged merged:$date_arg"

if [ "$dry_run" -eq 1 ]; then
  echo "search: $q"
  exit 0
fi

# shellcheck disable=SC2016  # $q and $after are GraphQL variables, not shell ones.
QUERY='query($q: String!, $after: String) {
  search(query: $q, type: ISSUE, first: 100, after: $after) {
    issueCount
    pageInfo { hasNextPage endCursor }
    nodes { ... on PullRequest {
      number title mergedAt
      repository { nameWithOwner }
      mergedBy { login }
      mergeCommit { abbreviatedOid }
      comments(last: '"$DEPTH"') { totalCount nodes { body } }
    } }
  }
}'

pages="$(mktemp)"
trap 'rm -f "$pages"' EXIT

after=""
while :; do
  args=(api graphql -f "query=$QUERY" -f "q=$q")
  [ -n "$after" ] && args+=(-f "after=$after")
  page="$(gh "${args[@]}")" || die "gh api graphql failed"
  jq -e '.data.search | (.issueCount | type == "number") and (.nodes | type == "array")' \
    >/dev/null 2>&1 <<<"$page" || die "unexpected response from GitHub"
  printf '%s\n' "$page" >>"$pages"
  count="$(jq -r '.data.search.issueCount' <<<"$page")"
  [ "$count" -le 1000 ] ||
    die "$count merges match and GitHub search returns at most 1000. Narrow --date, or audit one owner at a time."
  [ "$(jq -r '.data.search.pageInfo.hasNextPage' <<<"$page")" = "true" ] || break
  after="$(jq -r '.data.search.pageInfo.endCursor // empty' <<<"$page")"
  [ -n "$after" ] || die "GitHub reported another page without a cursor"
done

got="$(jq -s '[.[].data.search.nodes[] | select(.number)] | length' "$pages")" || die "could not read the response"
want="$(jq -s '.[0].data.search.issueCount' "$pages")" || die "could not read the response"
[ "$got" -ge "$want" ] || die "GitHub returned $got of $want merges; a partial list is not an audit"

report="$(jq -rs --arg date "$date_arg" --arg owners "$(IFS=,; echo "${owners[*]}")" --argjson depth "$DEPTH" '
  def attribution:
    [ .comments.nodes[].body
      | select(startswith("Merged by "))
      | capture("^Merged by (?<agent>.+?) under (?<rule>.+?)(?= \\(|,|\\.( |$)|\\n|$)")
    ] | first // null;
  def ref: "\(.repository.nameWithOwner)#\(.number)";
  def sha: .mergeCommit.abbreviatedOid // "-";

  [ .[].data.search.nodes[] | select(.number) | . + {attr: attribution} ]
  | map(select(.attr == null)) as $missing
  | map(select(.attr != null)) as $have
  | "== UNATTRIBUTED (\($missing | length))",
    ( $missing[]
      | "\(ref) | \(.title) | merged by \(.mergedBy.login // "unknown") | \(sha) | "
        + ( if .comments.totalCount > $depth
            then "not in the last \($depth) of \(.comments.totalCount) comments"
            else "no attribution comment" end ) ),
    "== BY AGENT AND RULE",
    ( $have | group_by([.attr.agent, .attr.rule])[]
      | "\(.[0].attr.agent) | \(.[0].attr.rule) (\(length))",
        ( .[] | "  \(ref) | \(.title) | \(sha)" ) ),
    "SUMMARY date=\($date) owners=\($owners) merged=\(length) attributed=\($have | length) unattributed=\($missing | length)"
' "$pages")" || die "could not read the response"

printf '%s\n' "$report"
case "$report" in
  *" unattributed=0") exit 0 ;;
  *) exit 1 ;;
esac
