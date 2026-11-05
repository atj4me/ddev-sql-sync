#!/usr/bin/env bash
## #ddev-generated: This file is managed by the sql-sync add-on (atj4me/ddev-sql-sync). It runs ON the remote server (piped over ssh by `ddev sql-sync`); do not edit the installed copy.
# sql-sync, remote side: write a MySQL dump of the app in $SQL_SYNC_ROOT to
# $SQL_SYNC_TMP/sql-sync.sql.
#
# Dump strategy, in order:
#   1. $SQL_SYNC_DUMP_CMD (the alias's dump: command) — its stdout is the dump.
#   2. The app's own export tool, if the platform has one and it is installed
#      here: WP-CLI for WordPress, Drush for Drupal. (Laravel has no native
#      data export, so it always uses strategy 3.)
#   3. mysqldump, with credentials resolved field by field: the alias's
#      database: block (arrives as SQL_SYNC_DB_*) wins; anything unset comes
#      from the app's own config on this server (.env / wp-config.php /
#      settings.php, per $SQL_SYNC_PLATFORM). The password is only ever
#      passed via MYSQL_PWD — never as a -p argument, never echoed.
set -euo pipefail

ROOT="${SQL_SYNC_ROOT:?sql-sync: SQL_SYNC_ROOT is not set}"
TMP_DIR="${SQL_SYNC_TMP:-/tmp}"
PLATFORM="${SQL_SYNC_PLATFORM:-}"
if [ -z "$PLATFORM" ]; then
  # No platform supplied (direct/manual use): assume laravel, never silently.
  PLATFORM="laravel"
  echo "sql-sync (remote): no platform specified (SQL_SYNC_PLATFORM unset); assuming laravel"
fi
echo "sql-sync (remote): platform: $PLATFORM"
DUMP_CMD="${SQL_SYNC_DUMP_CMD:-}"
OUT="$TMP_DIR/sql-sync.sql"

fail() {
  echo "sql-sync (remote): $*" >&2
  exit 1
}

cd "$ROOT" || fail "cannot cd to the app path $ROOT"

# --- Strategy 1: the alias's dump: command -----------------------------------

if [ -n "$DUMP_CMD" ]; then
  # It comes from the user's own aliases.yml and runs under their own ssh
  # account on their own server.
  echo "sql-sync (remote): using the alias's dump: command"
  eval "$DUMP_CMD" > "$OUT"
  ls -lh "$OUT"
  exit 0
fi

# --- Strategy 2: the app's own export tool ------------------------------------

if [ "$PLATFORM" = "wordpress" ] && command -v wp >/dev/null 2>&1; then
  echo "sql-sync (remote): using the app's own export: wp db export"
  wp db export "$OUT"
  ls -lh "$OUT"
  exit 0
fi

if [ "$PLATFORM" = "drupal" ]; then
  DRUSH_BIN="$(command -v drush || true)"
  if [ -z "$DRUSH_BIN" ] && [ -x "$ROOT/vendor/bin/drush" ]; then
    DRUSH_BIN="$ROOT/vendor/bin/drush"
  fi
  if [ -n "$DRUSH_BIN" ]; then
    echo "sql-sync (remote): using the app's own export: drush sql-dump"
    "$DRUSH_BIN" --root="$ROOT" sql-dump > "$OUT"
    ls -lh "$OUT"
    exit 0
  fi
fi

# --- Strategy 3: mysqldump -----------------------------------------------------

echo "sql-sync (remote): using mysqldump"

DB_DATABASE=""
DB_USERNAME=""
DB_PASSWORD=""
DB_HOST=""
DB_PORT=""
DB_SOCKET=""

extract_env() {
  # Laravel (and any .env app, e.g. Bedrock WordPress): DB_* from <root>/.env
  if [ ! -f .env ]; then
    echo "sql-sync (remote): no .env found in $ROOT; relying on the alias's database: block" >&2
    return 0
  fi
  read_env() {
    local line
    line="$(grep -E "^$1=" .env | tail -n 1)" || line=""
    line="${line#*=}"
    line="${line%\"}"
    line="${line#\"}"
    line="${line%\'}"
    line="${line#\'}"
    printf '%s' "$line"
  }
  DB_DATABASE="$(read_env DB_DATABASE)"
  DB_USERNAME="$(read_env DB_USERNAME)"
  DB_PASSWORD="$(read_env DB_PASSWORD)"
  DB_HOST="$(read_env DB_HOST)"
  DB_PORT="$(read_env DB_PORT)"
}

extract_wordpress() {
  # Classic WordPress: DB_* define() lines in wp-config.php (which WordPress
  # also allows one level above the app root).
  local cfg="wp-config.php"
  if [ ! -f "$cfg" ] && [ -f ../wp-config.php ]; then
    cfg="../wp-config.php"
  fi
  if [ ! -f "$cfg" ]; then
    echo "sql-sync (remote): wp-config.php not found in $ROOT; relying on the alias's database: block" >&2
    return 0
  fi
  wp_define() {
    local line
    line="$(grep -E "^[[:space:]]*define\([[:space:]]*['\"]$1['\"]" "$cfg" | head -n 1)" || line=""
    [ -z "$line" ] && return 0
    printf '%s' "$line" | sed -E "s/^.*define\([[:space:]]*['\"]$1['\"][[:space:]]*,[[:space:]]*//; s/[[:space:]]*\);?[[:space:]]*\$//; s/^'(.*)'\$/\1/; s/^\"(.*)\"\$/\1/"
  }
  DB_DATABASE="$(wp_define DB_NAME)"
  DB_USERNAME="$(wp_define DB_USER)"
  DB_PASSWORD="$(wp_define DB_PASSWORD)"
  DB_HOST="$(wp_define DB_HOST)"
  # DB_HOST may be 'host', 'host:port' or 'localhost:/path/to.sock'.
  case "$DB_HOST" in
    *:*)
      local h="${DB_HOST%%:*}"
      local rest="${DB_HOST#*:}"
      if [[ "$rest" =~ ^[0-9]+$ ]]; then
        DB_HOST="$h"
        DB_PORT="$rest"
      elif [ "${rest#/}" != "$rest" ]; then
        DB_HOST="localhost"
        DB_SOCKET="$rest"
      fi
      ;;
  esac
}

extract_drupal() {
  # Drupal: the default $databases entry in sites/default/settings.php,
  # read with a small PHP snippet (settings.php normally just assigns it).
  local settings=""
  local candidate
  for candidate in "$ROOT/sites/default/settings.php" "$ROOT/web/sites/default/settings.php" "$ROOT/docroot/sites/default/settings.php"; do
    if [ -f "$candidate" ]; then
      settings="$candidate"
      break
    fi
  done
  if [ -z "$settings" ]; then
    echo "sql-sync (remote): settings.php not found under $ROOT; relying on the alias's database: block" >&2
    return 0
  fi
  if ! command -v php >/dev/null 2>&1; then
    echo "sql-sync (remote): php is not available on this server, so settings.php cannot be read; relying on the alias's database: block" >&2
    return 0
  fi
  local extractor
  extractor="$(mktemp "$TMP_DIR/sql-sync-extract-XXXXXX")"
  cat > "$extractor" <<'PHP'
<?php
$settings_file = $argv[1] ?? '';
$databases = [];
$app_root = dirname($settings_file, 3);
$site_path = 'sites/default';
try {
    include $settings_file;
} catch (Throwable $e) {
    fwrite(STDERR, 'sql-sync (remote): could not load settings.php: ' . $e->getMessage() . "\n");
    exit(1);
}
$db = $databases['default']['default'] ?? null;
if (!is_array($db) || empty($db['database']) || empty($db['username'])) {
    fwrite(STDERR, "sql-sync (remote): no default \$databases entry found in settings.php\n");
    exit(1);
}
echo ($db['database'] ?? '') . "\n";
echo ($db['username'] ?? '') . "\n";
echo ($db['password'] ?? '') . "\n";
echo ($db['host'] ?? '') . "\n";
echo ($db['port'] ?? '') . "\n";
PHP
  local creds
  if ! creds="$(php "$extractor" "$settings")"; then
    rm -f "$extractor"
    echo "sql-sync (remote): could not read credentials from $settings; relying on the alias's database: block" >&2
    return 0
  fi
  rm -f "$extractor"
  # mapfile, not a read loop: the extractor's trailing empty fields (e.g. an
  # empty port) would otherwise make the last read hit EOF and, under
  # set -e, kill the script after a successful extraction.
  local -a cred_lines=()
  mapfile -t cred_lines <<< "$creds"
  DB_DATABASE="${cred_lines[0]:-}"
  DB_USERNAME="${cred_lines[1]:-}"
  DB_PASSWORD="${cred_lines[2]:-}"
  DB_HOST="${cred_lines[3]:-}"
  DB_PORT="${cred_lines[4]:-}"
}

case "$PLATFORM" in
  laravel) extract_env ;;
  wordpress) extract_wordpress ;;
  drupal) extract_drupal ;;
  *) fail "unknown platform '$PLATFORM' (expected laravel, wordpress or drupal — or set a 'dump:' command in the alias)" ;;
esac

# Explicit values from the alias's database: block win, field by field.
[ -n "${SQL_SYNC_DB_NAME:-}" ] && DB_DATABASE="$SQL_SYNC_DB_NAME"
[ -n "${SQL_SYNC_DB_USERNAME:-}" ] && DB_USERNAME="$SQL_SYNC_DB_USERNAME"
[ -n "${SQL_SYNC_DB_PASSWORD:-}" ] && DB_PASSWORD="$SQL_SYNC_DB_PASSWORD"
[ -n "${SQL_SYNC_DB_HOST:-}" ] && DB_HOST="$SQL_SYNC_DB_HOST"
[ -n "${SQL_SYNC_DB_PORT:-}" ] && DB_PORT="$SQL_SYNC_DB_PORT"

[ -n "$DB_DATABASE" ] || fail "no database name: not set in the alias's database: block and not found in the app config in $ROOT"
[ -n "$DB_USERNAME" ] || fail "no database username: not set in the alias's database: block and not found in the app config in $ROOT"

EXTRA=""
if [ -n "$DB_SOCKET" ]; then
  EXTRA="$EXTRA --socket=$(printf '%q' "$DB_SOCKET")"
elif [ -n "$DB_HOST" ] && [ "$DB_HOST" != "localhost" ]; then
  EXTRA="$EXTRA -h $(printf '%q' "$DB_HOST")"
fi
[ -n "$DB_PORT" ] && EXTRA="$EXTRA -P $(printf '%q' "$DB_PORT")"

# $EXTRA is intentionally unquoted: it holds separate, %q-quoted options.
MYSQL_PWD="$DB_PASSWORD" mysqldump $EXTRA -u "$DB_USERNAME" --single-transaction --quick --no-tablespaces --skip-lock-tables "$DB_DATABASE" > "$OUT"
ls -lh "$OUT"
