#!/usr/bin/env bash
# Idempotent toolchain for Cursor Cloud Agents. Safe to run more than once.
# Installs the packages the helper, the regression tests, and shell checks use.
# Does not call GitHub. A missing token is a warning, not a failed install.
set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
  as_root() {
    env DEBIAN_FRONTEND=noninteractive "$@"
  }
else
  as_root() {
    sudo -n env DEBIAN_FRONTEND=noninteractive "$@"
  }
fi

as_root apt-get update
as_root apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  git \
  jq \
  python3 \
  gh \
  shellcheck \
  shfmt \
  bats \
  bsdextrautils

for cmd in gh jq python3 shellcheck shfmt bats git column; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "error: ${cmd} is not on PATH after install" >&2
    exit 1
  fi
done

if [ -z "${GH_TOKEN:-}" ] && [ -z "${GITHUB_TOKEN:-}" ]; then
  echo "warning: GH_TOKEN is not set and GITHUB_TOKEN is not set. gh commands that need GitHub authentication will fail until one of them is set. Install continues." >&2
fi
