#!/usr/bin/env bash
# files_pull_command helper for the generated sql-sync provider: rsyncs
# the alias's remote user-files directory into .ddev/.downloads/files,
# where ddev pull's default files import takes over.
set -euo pipefail

ADDON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPROOT="$(cd "$ADDON_DIR/../.." && pwd)"
ALIASES_FILE="$ADDON_DIR/aliases.yml"
# shellcheck source=lib.sh
. "$ADDON_DIR/lib.sh"

ALIAS="${1:-}"
[ -n "$ALIAS" ] || sqlsync_fail "pull-files: an alias argument is required"
load_alias "$ALIAS"
[ -n "$FILES_DIR" ] || sqlsync_fail "pull-files: alias '@$ALIAS' has no 'files:' key in .ddev/sql-sync/aliases.yml"

DEST="$APPROOT/.ddev/.downloads/files"
mkdir -p "$DEST"
echo "==> [files] Downloading $SSH_TARGET:$FILES_DIR/ to .ddev/.downloads/files ..."
# $SSH_OPTIONS is intentionally unquoted: it holds separate ssh options.
rsync -az -e "ssh $SSH_OPTIONS" "$SSH_TARGET:${FILES_DIR%/}/" "$DEST/" \
  || sqlsync_fail "failed to download the files from $SSH_TARGET:$FILES_DIR"
