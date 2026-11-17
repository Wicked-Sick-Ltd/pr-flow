#!/usr/bin/env bash
# Offline checks for the Cloud Agent install. Uses a fake apt-get. No network.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
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

python3 - <<PY
import json
from pathlib import Path
doc = json.loads(Path("$ROOT/.cursor/environment.json").read_text())
keys = set(doc)
if keys != {"name", "install"}:
    raise SystemExit("environment.json keys: %s" % sorted(keys))
if doc["install"] != "bash .cursor/install.sh":
    raise SystemExit("install command: %s" % doc["install"])
if not isinstance(doc["name"], str) or not doc["name"].strip():
    raise SystemExit("name must be a non-empty string")
if "\$schema" in doc:
    raise SystemExit("environment.json must not set \$schema")
PY
ok "environment.json install command"

BIN="$(mktemp -d)"
trap 'rm -rf "$BIN"' EXIT

cat >"$BIN/sudo" <<'EOF'
#!/bin/bash
set -euo pipefail
if [ "${1:-}" = "-n" ]; then
  shift
fi
if [ "${1:-}" = "env" ]; then
  shift
  while [ "$#" -gt 0 ] && [[ "$1" == *=* ]]; do
    shift
  done
fi
exec "$@"
EOF
chmod 755 "$BIN/sudo"

cat >"$BIN/apt-get" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >>"${APT_LOG:?}"
EOF
chmod 755 "$BIN/apt-get"

for cmd in gh jq python3 shellcheck shfmt bats git column; do
  printf '#!/bin/sh\nexit 0\n' >"$BIN/$cmd"
  chmod 755 "$BIN/$cmd"
done

run_install() {
  local log="$1"
  shift
  APT_LOG="$log" PATH="$BIN:/usr/bin:/bin" \
    env -u GH_TOKEN -u GITHUB_TOKEN "$@" \
    bash "$ROOT/.cursor/install.sh" >"$log.out" 2>"$log.err"
}

LOG="$BIN/apt.log"
: >"$LOG"
if run_install "$LOG"; then
  ok "install exits 0 with no token"
else
  fail "install exits 0 with no token ($?)"
fi

if grep -q "GH_TOKEN" "$LOG.err" && grep -q "GITHUB_TOKEN" "$LOG.err"; then
  ok "missing token warning names GH_TOKEN and GITHUB_TOKEN"
else
  fail "missing token warning names GH_TOKEN and GITHUB_TOKEN"
  cat "$LOG.err" >&2
fi

if [ ! -s "$LOG.out" ]; then
  ok "install prints no stdout"
else
  fail "install prints no stdout"
fi

for pkg in ca-certificates curl git jq python3 gh shellcheck shfmt bats bsdextrautils; do
  if grep -q -- "$pkg" "$LOG"; then
    ok "install requests $pkg"
  else
    fail "install requests $pkg"
  fi
done

if run_install "$LOG"; then
  ok "second install exits 0"
else
  fail "second install exits 0 ($?)"
fi

updates="$(grep -c '^update$' "$LOG" || true)"
if [ "$updates" -eq 2 ]; then
  ok "second install updates apt again"
else
  fail "second install updates apt again (count=$updates)"
fi

LOG2="$BIN/apt-token.log"
: >"$LOG2"
if APT_LOG="$LOG2" PATH="$BIN:/usr/bin:/bin" \
  env -u GITHUB_TOKEN GH_TOKEN=present \
  bash "$ROOT/.cursor/install.sh" >"$LOG2.out" 2>"$LOG2.err"; then
  ok "install exits 0 when GH_TOKEN is set"
else
  fail "install exits 0 when GH_TOKEN is set ($?)"
fi

if [ ! -s "$LOG2.err" ] && ! grep -q "present" "$LOG2.out" "$LOG2.err"; then
  ok "set GH_TOKEN is not warned and not printed"
else
  fail "set GH_TOKEN is not warned and not printed"
  cat "$LOG2.err" >&2
fi

LOG3="$BIN/apt-github-token.log"
: >"$LOG3"
if APT_LOG="$LOG3" PATH="$BIN:/usr/bin:/bin" \
  env -u GH_TOKEN GITHUB_TOKEN=present \
  bash "$ROOT/.cursor/install.sh" >"$LOG3.out" 2>"$LOG3.err"; then
  ok "install exits 0 when GITHUB_TOKEN is set"
else
  fail "install exits 0 when GITHUB_TOKEN is set ($?)"
fi

if [ ! -s "$LOG3.err" ] && ! grep -q "present" "$LOG3.out" "$LOG3.err"; then
  ok "set GITHUB_TOKEN is not warned and not printed"
else
  fail "set GITHUB_TOKEN is not warned and not printed"
  cat "$LOG3.err" >&2
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
