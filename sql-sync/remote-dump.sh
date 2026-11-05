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
  # No platform supplied (direct/manual use): assume php, never silently.
  PLATFORM="php"
  echo "sql-sync (remote): no platform specified (SQL_SYNC_PLATFORM unset); assuming php"
fi
echo "sql-sync (remote): platform: $PLATFORM"
PREFLIGHT="${SQL_SYNC_PREFLIGHT:-}"
PREFLIGHT_FAILED=""
DUMP_CMD="${SQL_SYNC_DUMP_CMD:-}"
OUT="$TMP_DIR/sql-sync.sql"

fail() {
  echo "sql-sync (remote): $*" >&2
  exit 1
}

cd "$ROOT" || fail "cannot cd to the app path $ROOT"

# --- Strategy selection (nothing is executed yet) -------------------------------

STRATEGY=""
STRATEGY_LABEL=""
DRUSH_BIN=""
if [ -n "$DUMP_CMD" ]; then
  STRATEGY="dump"
  STRATEGY_LABEL="the alias's dump: command"
elif [ "$PLATFORM" = "wordpress" ] && command -v wp >/dev/null 2>&1; then
  STRATEGY="wp"
  STRATEGY_LABEL="wp db export (the app's own export)"
elif [ "$PLATFORM" = "drupal" ]; then
  DRUSH_BIN="$(command -v drush || true)"
  if [ -z "$DRUSH_BIN" ] && [ -x "$ROOT/vendor/bin/drush" ]; then
    DRUSH_BIN="$ROOT/vendor/bin/drush"
  fi
  if [ -n "$DRUSH_BIN" ]; then
    STRATEGY="drush"
    STRATEGY_LABEL="drush sql-dump (the app's own export)"
  fi
fi
if [ -z "$STRATEGY" ]; then
  STRATEGY="mysqldump"
  STRATEGY_LABEL="mysqldump"
fi

# --- Credential resolution ------------------------------------------------------

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

resolve_app_credentials() {
case "$PLATFORM" in
  laravel) extract_env ;;
  php) extract_env ;;
  wordpress) extract_wordpress ;;
  drupal) extract_drupal ;;
  *) fail "unknown platform '$PLATFORM' (expected laravel, wordpress, drupal or php — or set a 'dump:' command in the alias)" ;;
esac
}

# Explicit values from the alias's database: block win, field by field.
apply_db_overrides() {
  if [ -n "${SQL_SYNC_DB_NAME:-}" ]; then DB_DATABASE="$SQL_SYNC_DB_NAME"; fi
  if [ -n "${SQL_SYNC_DB_USERNAME:-}" ]; then DB_USERNAME="$SQL_SYNC_DB_USERNAME"; fi
  if [ -n "${SQL_SYNC_DB_PASSWORD:-}" ]; then DB_PASSWORD="$SQL_SYNC_DB_PASSWORD"; fi
  if [ -n "${SQL_SYNC_DB_HOST:-}" ]; then DB_HOST="$SQL_SYNC_DB_HOST"; fi
  if [ -n "${SQL_SYNC_DB_PORT:-}" ]; then DB_PORT="$SQL_SYNC_DB_PORT"; fi
}

if [ "$STRATEGY" = "mysqldump" ]; then
  resolve_app_credentials
  apply_db_overrides
elif [ "$STRATEGY" = "wp" ] || [ "$STRATEGY" = "drush" ]; then
  # Best effort, for the size estimate only; never fatal, never printed.
  { resolve_app_credentials; apply_db_overrides; } 2>/dev/null || true
fi


if [ "$STRATEGY" = "mysqldump" ]; then
  if [ -n "$PREFLIGHT" ]; then
    [ -n "$DB_DATABASE" ] || PREFLIGHT_FAILED=1
    [ -n "$DB_USERNAME" ] || PREFLIGHT_FAILED=1
  else
    [ -n "$DB_DATABASE" ] || fail "no database name: not set in the alias's database: block and not found in the app config in $ROOT"
    [ -n "$DB_USERNAME" ] || fail "no database username: not set in the alias's database: block and not found in the app config in $ROOT"
  fi
fi

EXTRA=""
if [ -n "$DB_SOCKET" ]; then
  EXTRA="$EXTRA --socket=$(printf '%q' "$DB_SOCKET")"
elif [ -n "$DB_HOST" ] && [ "$DB_HOST" != "localhost" ]; then
  EXTRA="$EXTRA -h $(printf '%q' "$DB_HOST")"
fi
[ -n "$DB_PORT" ] && EXTRA="$EXTRA -P $(printf '%q' "$DB_PORT")"

# $EXTRA is intentionally unquoted: it holds separate, %q-quoted options.

# --- Database size and free space ----------------------------------------------

fmt_bytes() {
  local b="$1"
  if [ "$b" -ge 1073741824 ]; then printf '%d.%d GB' $((b / 1073741824)) $(((b % 1073741824) * 10 / 1073741824))
  elif [ "$b" -ge 1048576 ]; then printf '%d.%d MB' $((b / 1048576)) $(((b % 1048576) * 10 / 1048576))
  elif [ "$b" -ge 1024 ]; then printf '%d.%d KB' $((b / 1024)) $(((b % 1024) * 10 / 1024))
  else printf '%d B' "$b"; fi
}

DB_SIZE_BYTES=""
if [ -n "$DB_DATABASE" ] && [ -n "$DB_USERNAME" ] && command -v mysql >/dev/null 2>&1; then
  DB_SIZE_BYTES="$(MYSQL_PWD="$DB_PASSWORD" mysql $EXTRA -u "$DB_USERNAME" -N -B -e "SELECT COALESCE(SUM(data_length + index_length), 0) FROM information_schema.tables WHERE table_schema = '${DB_DATABASE//\'/}'" 2>/dev/null || true)"
  case "$DB_SIZE_BYTES" in ''|*[!0-9]*) DB_SIZE_BYTES="" ;; esac
fi

TMP_FREE_BYTES=""
_df_out="$(df -Pk "$TMP_DIR" 2>/dev/null || true)"
_df_last="${_df_out##*$'\n'}"
_df_kb=""
read -r _df_fs _df_blocks _df_used _df_kb _df_rest <<< "$_df_last" || true
case "$_df_kb" in ''|*[!0-9]*) ;; *) TMP_FREE_BYTES=$((_df_kb * 1024)) ;; esac

# --- Preflight gate: in preflight mode the run stops here, before any ---------
# --- dump is executed and before anything is written on this server. -----------

if [ -n "$PREFLIGHT" ]; then
  echo "preflight: strategy: $STRATEGY_LABEL"
  if [ "$STRATEGY" = "mysqldump" ]; then
    if command -v mysqldump >/dev/null 2>&1; then
      echo "preflight: ok: mysqldump is available on this server"
    else
      echo "preflight: FAIL: mysqldump is not installed on this server"
      PREFLIGHT_FAILED=1
    fi
    if [ -n "$DB_DATABASE" ]; then
      echo "preflight: database: $DB_DATABASE"
    else
      echo "preflight: FAIL: no database name could be resolved (not in the alias's database: block, not in the app config)"
      PREFLIGHT_FAILED=1
    fi
    if [ -n "$DB_USERNAME" ]; then
      echo "preflight: username: $DB_USERNAME"
    else
      echo "preflight: FAIL: no database username could be resolved (not in the alias's database: block, not in the app config)"
      PREFLIGHT_FAILED=1
    fi
    if [ -n "$DB_PASSWORD" ]; then
      echo "preflight: password: resolved (never shown)"
    else
      echo "preflight: password: not resolved (empty)"
    fi
  fi
  if [ -n "$DB_SIZE_BYTES" ]; then
    echo "preflight: database size: ~$(fmt_bytes "$DB_SIZE_BYTES") (information_schema estimate)"
  else
    echo "preflight: database size: unknown (could not be estimated)"
  fi
  if [ -w "$TMP_DIR" ]; then
    echo "preflight: ok: tmp dir $TMP_DIR is writable"
  else
    echo "preflight: FAIL: tmp dir $TMP_DIR is not writable"
    PREFLIGHT_FAILED=1
  fi
  if [ -n "$TMP_FREE_BYTES" ]; then
    echo "preflight: tmp free space: $(fmt_bytes "$TMP_FREE_BYTES")"
  else
    echo "preflight: tmp free space: unknown"
  fi
  if [ -n "$DB_SIZE_BYTES" ] && [ -n "$TMP_FREE_BYTES" ]; then
    if [ "$TMP_FREE_BYTES" -ge "$DB_SIZE_BYTES" ]; then
      echo "preflight: ok: free space covers the estimated database size"
    else
      echo "preflight: FAIL: free space in $TMP_DIR ($(fmt_bytes "$TMP_FREE_BYTES")) is less than the estimated database size ($(fmt_bytes "$DB_SIZE_BYTES"))"
      PREFLIGHT_FAILED=1
    fi
  fi
  if [ "$PREFLIGHT_FAILED" = "1" ]; then
    echo "preflight: FAILED — a real run would not proceed"
    exit 1
  fi
  echo "preflight: all checks passed"
  exit 0
fi

# --- Disk-space guard ------------------------------------------------------------

if [ -n "$DB_SIZE_BYTES" ] && [ -n "$TMP_FREE_BYTES" ] && [ "$TMP_FREE_BYTES" -lt "$DB_SIZE_BYTES" ]; then
  fail "not enough free space in $TMP_DIR on this server for the dump: $(fmt_bytes "$TMP_FREE_BYTES") free, but the database is ~$(fmt_bytes "$DB_SIZE_BYTES"). Free some space, or point the alias's tmp: at a larger filesystem. Nothing was dumped."
fi

# --- Execute the dump --------------------------------------------------------------

case "$STRATEGY" in
  dump)
    # The dump: command comes from the user's own aliases.yml and runs under
    # their own ssh account on their own server.
    echo "sql-sync (remote): using the alias's dump: command"
    eval "$DUMP_CMD" > "$OUT"
    ;;
  wp)
    echo "sql-sync (remote): using the app's own export: wp db export"
    wp db export "$OUT"
    ;;
  drush)
    echo "sql-sync (remote): using the app's own export: drush sql-dump"
    "$DRUSH_BIN" --root="$ROOT" sql-dump > "$OUT"
    ;;
  mysqldump)
    echo "sql-sync (remote): using mysqldump"
    MYSQL_PWD="$DB_PASSWORD" mysqldump $EXTRA -u "$DB_USERNAME" --single-transaction --quick --no-tablespaces --skip-lock-tables "$DB_DATABASE" > "$OUT"
    ;;
esac
ls -lh "$OUT"
