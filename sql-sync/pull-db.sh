#!/usr/bin/env bash
# db_pull_command helper for the generated sql-sync provider: creates the
# dump on the server (unless SQL_SYNC_NO_DUMP is set), rsyncs it and its
# completion marker down, verifies the size, and leaves the result where
# ddev pull expects it (.ddev/.downloads/db.sql.gz), plus the kept copy in
# the alias's local dump dir. Any failure exits non-zero, which makes
# ddev pull abort before the import stage.
set -euo pipefail

ADDON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPROOT="$(cd "$ADDON_DIR/../.." && pwd)"
ALIASES_FILE="$ADDON_DIR/aliases.yml"
# shellcheck source=lib.sh
. "$ADDON_DIR/lib.sh"

ALIAS="${1:-}"
[ -n "$ALIAS" ] || sqlsync_fail "pull-db: an alias argument is required"
load_alias "$ALIAS"

case "${SQL_SYNC_NO_DUMP:-}" in 1|true) NO_DUMP="true" ;; *) NO_DUMP="false" ;; esac
case "${SQL_SYNC_SANITIZE:-}" in false|0) SANITIZE_EFFECTIVE="false" ;; *) SANITIZE_EFFECTIVE="true" ;; esac

DUMP_DIR="$(resolve_dump_dir "${SQL_SYNC_DUMP_DIR:-}")"
mkdir -p "$DUMP_DIR"
DUMP_FILE="$DUMP_DIR/$ALIAS.sql"
MARKER_FILE="$DUMP_DIR/.$ALIAS.done"
WP_PREFIX=""

echo "sql-sync: @$ALIAS ($SSH_TARGET:$ALIAS_ROOT, platform: $PLATFORM) -> @self"

if [ "$NO_DUMP" = "true" ]; then
  echo "==> [pull] Skipping dump creation (SQL_SYNC_NO_DUMP); expecting an existing dump at $SSH_TARGET:$REMOTE_FILE"
else
  echo "==> [pull] Creating dump on $SSH_TARGET ..."
  STEP1_OUT=""
  STEP1_RC=0
  # $SSH_OPTIONS is intentionally unquoted: it holds separate ssh options.
  STEP1_OUT="$(ssh $SSH_OPTIONS "$SSH_TARGET" "$REMOTE_ENV bash -s" < "$ADDON_DIR/remote-dump.sh" 2>&1)" || STEP1_RC=$?
  [ -n "$STEP1_OUT" ] && printf '%s\n' "$STEP1_OUT"
  if [ "$STEP1_RC" -ne 0 ]; then
    sqlsync_fail "the dump step failed on $SSH_TARGET (exit $STEP1_RC); nothing was downloaded or imported"
  fi
  WP_PREFIX="$(printf '%s\n' "$STEP1_OUT" | sed -n 's/^sql-sync-meta: wp_prefix=//p' | head -n 1)"
  case "$WP_PREFIX" in *[!A-Za-z0-9_]*) WP_PREFIX="" ;; esac
fi

echo "==> [pull] Downloading dump to $DUMP_FILE ..."
rsync -az -e "ssh $SSH_OPTIONS" "$SSH_TARGET:$REMOTE_FILE" "$DUMP_FILE" \
  || sqlsync_fail "failed to download the dump from $SSH_TARGET:$REMOTE_FILE (for --no-dump runs: an earlier --no-sync run must have left one there)"
rsync -az -e "ssh $SSH_OPTIONS" "$SSH_TARGET:$REMOTE_DONE" "$MARKER_FILE" \
  || sqlsync_fail "the dump's completion marker ($REMOTE_DONE) could not be downloaded — the dump on the server may be incomplete; refusing to import. Re-run without --no-dump to create a fresh dump."
EXPECTED_SIZE="$(tr -d '[:space:]' < "$MARKER_FILE")"
case "$EXPECTED_SIZE" in
  ''|*[!0-9]*) sqlsync_fail "the dump's completion marker is unreadable ('$EXPECTED_SIZE'); refusing to import" ;;
esac
ACTUAL_SIZE="$(wc -c < "$DUMP_FILE" | tr -d '[:space:]')"
if [ "$ACTUAL_SIZE" != "$EXPECTED_SIZE" ]; then
  sqlsync_fail "the downloaded dump is $ACTUAL_SIZE bytes but the server's completion marker says $EXPECTED_SIZE — the transfer is incomplete; refusing to import"
fi
rm -f "$MARKER_FILE"
echo "    verified: $ACTUAL_SIZE bytes, matching the server's completion marker"

if [ "$(head -c 2 "$DUMP_FILE" | od -An -tx1 | tr -d ' \n')" = "1f8b" ]; then
  mv "$DUMP_FILE" "$DUMP_FILE.gz"
  DUMP_FILE="$DUMP_FILE.gz"
  echo "    the dump is gzipped; the kept copy is $DUMP_FILE"
fi

mkdir -p "$APPROOT/.ddev/.downloads"
if [ "${DUMP_FILE##*.}" = "gz" ]; then
  cp "$DUMP_FILE" "$APPROOT/.ddev/.downloads/db.sql.gz"
else
  gzip -c "$DUMP_FILE" > "$APPROOT/.ddev/.downloads/db.sql.gz"
fi

STATE_DIR="$ADDON_DIR/.state"
mkdir -p "$STATE_DIR"
{
  printf 'ALIAS=%q\n' "$ALIAS"
  printf 'PLATFORM=%q\n' "$PLATFORM"
  printf 'WP_PREFIX=%q\n' "$WP_PREFIX"
  printf 'SANITIZE=%q\n' "$SANITIZE_EFFECTIVE"
  printf 'SANITIZE_KEY=%q\n' "$SANITIZE_KEY"
  printf 'SANITIZE_OVERRIDE=%q\n' "$SANITIZE_OVERRIDE"
  printf 'SSH_TARGET=%q\n' "$SSH_TARGET"
  printf 'SSH_OPTIONS=%q\n' "$SSH_OPTIONS"
  printf 'REMOTE_FILE=%q\n' "$REMOTE_FILE"
  printf 'REMOTE_DONE=%q\n' "$REMOTE_DONE"
  printf 'DUMP_FILE=%q\n' "$DUMP_FILE"
} > "$STATE_DIR/$ALIAS.env"
echo "==> [pull] Dump ready for import: .ddev/.downloads/db.sql.gz (kept copy: $DUMP_FILE)"
