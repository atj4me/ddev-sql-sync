#!/usr/bin/env bash
# auth_command helper for the generated sql-sync provider: a BatchMode
# ssh connectivity check that runs before db_pull and fails the pull fast
# when the server cannot be reached, instead of mid-dump.
set -euo pipefail

ADDON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPROOT="$(cd "$ADDON_DIR/../.." && pwd)"
ALIASES_FILE="$ADDON_DIR/aliases.yml"
# shellcheck source=lib.sh
. "$ADDON_DIR/lib.sh"

ALIAS="${1:-}"
[ -n "$ALIAS" ] || sqlsync_fail "auth-check: an alias argument is required"
load_alias "$ALIAS"

# $SSH_OPTIONS is intentionally unquoted: it holds separate ssh options.
if ! ssh -o BatchMode=yes -o ConnectTimeout=10 $SSH_OPTIONS "$SSH_TARGET" true; then
  sqlsync_fail "cannot reach $SSH_TARGET over ssh (BatchMode, 10s timeout) — check your keys and ~/.ssh/config, then try again"
fi
echo "sql-sync: ssh to $SSH_TARGET ok"
