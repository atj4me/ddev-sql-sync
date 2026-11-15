#!/usr/bin/env bash
# db_import_command helper for the generated sql-sync provider: imports
# the downloaded dump with ddev import-db, sanitizes, and only then
# deletes the remote temp files. Any failure exits non-zero (and the
# remote dump is kept), which makes ddev pull report the failure.
set -euo pipefail

ADDON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPROOT="$(cd "$ADDON_DIR/../.." && pwd)"
ALIASES_FILE="$ADDON_DIR/aliases.yml"
# shellcheck source=lib.sh
. "$ADDON_DIR/lib.sh"

ALIAS="${1:-}"
[ -n "$ALIAS" ] || sqlsync_fail "import-db: an alias argument is required"

STATE_FILE="$ADDON_DIR/.state/$ALIAS.env"
[ -f "$STATE_FILE" ] || sqlsync_fail "import-db: no pull state found for '@$ALIAS' ($STATE_FILE) — the db_pull stage must run first"
# shellcheck disable=SC1090
. "$STATE_FILE"

DOWNLOAD_FILE="$APPROOT/.ddev/.downloads/db.sql.gz"
[ -f "$DOWNLOAD_FILE" ] || sqlsync_fail "import-db: $DOWNLOAD_FILE is missing — the db_pull stage must run first"

echo "==> [import] Importing into this DDEV project ..."
if ! ddev import-db --file="$DOWNLOAD_FILE"; then
  echo "sql-sync: the import FAILED — the local database may be incomplete." >&2
  echo "The dump has been kept on the server at $SSH_TARGET:$REMOTE_FILE (marker: $REMOTE_DONE)" >&2
  echo "and locally at $DUMP_FILE. Fix the problem, then fetch and import it with:" >&2
  echo "  ddev sql-sync @$ALIAS @self --no-dump" >&2
  exit 1
fi

echo "==> [import] Sanitize ..."
SANITIZED=""
if [ "$SANITIZE" != "true" ]; then
  echo "    SKIPPED (--no-sanitize). WARNING: the local database now contains real"
  echo "    production user emails and password hashes. Handle the kept dump in"
  echo "    $(dirname "$DUMP_FILE") accordingly and delete it when you are done."
elif [ "$PLATFORM" = "drupal" ] && [ -z "$SANITIZE_OVERRIDE" ] && ddev drush --version >/dev/null 2>&1; then
  ddev drush sql-sanitize --yes
  SANITIZED=1
  echo "    Sanitized with Drush sql-sanitize (user emails and passwords scrubbed)."
elif [ -n "$SANITIZE_OVERRIDE" ]; then
  ddev mysql < "$SANITIZE_OVERRIDE"
  SANITIZED=1
  echo "    Sanitized with the alias's sanitize file: $SANITIZE_KEY"
elif [ "$PLATFORM" = "laravel" ] && [ -f "$ADDON_DIR/sanitize-laravel.sql" ]; then
  if ddev mysql -N -e "SHOW TABLES LIKE 'users';" | grep -qx "users"; then
    ddev mysql < "$ADDON_DIR/sanitize-laravel.sql"
    SANITIZED=1
    echo "    Sanitized: user emails are now user<id>@example.test and passwords are 'password'."
  else
    echo "    No 'users' table in the imported database — sanitize did NOT run."
  fi
elif [ "$PLATFORM" = "wordpress" ] && [ -f "$ADDON_DIR/sanitize-wordpress.sql" ]; then
  WP_USERS_TABLE=""
  if [ -n "$WP_PREFIX" ]; then
    if ddev mysql -N -e "SHOW TABLES LIKE '${WP_PREFIX}users';" | grep -qx "${WP_PREFIX}users"; then
      WP_USERS_TABLE="${WP_PREFIX}users"
    fi
  else
    ALL_TABLES="$(ddev mysql -N -e "SHOW TABLES;")"
    for t in $ALL_TABLES; do
      case "$t" in
        *users)
          pfx="${t%users}"
          if printf '%s\n' "$ALL_TABLES" | grep -qx "${pfx}options"; then
            WP_USERS_TABLE="$t"
            break
          fi
          ;;
      esac
    done
  fi
  if [ -n "$WP_USERS_TABLE" ]; then
    sed "s/__PREFIX__/${WP_USERS_TABLE%users}/g" "$ADDON_DIR/sanitize-wordpress.sql" | ddev mysql
    SANITIZED=1
    echo "    Sanitized: user emails are now user<id>@example.test and passwords are 'password' (table: $WP_USERS_TABLE)."
  else
    echo "    No WordPress users table found in the imported database — sanitize did NOT run."
  fi
elif [ "$PLATFORM" = "drupal" ]; then
  echo "    No sanitize ran: Drupal hashes passwords in PHP, so there is no bundled"
  echo "    SQL sanitize. Install Drush in this project (then ddev drush sql-sanitize"
  echo "    is used automatically), or set a 'sanitize:' SQL file in the alias."
  echo "    The imported database has NOT been sanitized."
else
  echo "    No sanitize available for platform '$PLATFORM': set a 'sanitize:' SQL file"
  echo "    in the alias to enable one. The imported database has NOT been sanitized."
fi

if [ "$SANITIZE" = "true" ] && [ -z "$SANITIZED" ]; then
  echo "" >&2
  echo "sql-sync: ERROR: the import completed WITHOUT sanitize." >&2
  echo "The local database now holds LIVE production user emails and password hashes." >&2
  echo "The dump has been kept on the server at $SSH_TARGET:$REMOTE_FILE for a retry." >&2
  echo "Sanitize it yourself, set a 'sanitize:' file in the alias, or re-run with" >&2
  echo "--no-sanitize to accept an unsanitized import explicitly." >&2
  exit 1
fi

echo "==> [import] Removing the remote temp files ..."
# $SSH_OPTIONS is intentionally unquoted: it holds separate ssh options.
ssh $SSH_OPTIONS "$SSH_TARGET" "rm -f $(printf '%q' "$REMOTE_FILE") $(printf '%q' "$REMOTE_DONE")"
echo "sql-sync: done. @$ALIAS is now this project's database."
