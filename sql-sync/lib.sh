# Shared alias loading for the sql-sync launcher and the ddev pull helpers.
# Sourced, not executed. Expects APPROOT and ADDON_DIR to be set, and
# ALIASES_FILE to point at the user's aliases.yml.

sqlsync_fail() {
  echo "sql-sync: $*" >&2
  exit 1
}

# Read one key from one section of the aliases file. Only keys at the
# section's own indent level match, so the nested database: block's keys
# (host, port, ...) are never confused with the alias's own keys.
alias_value() {
  local section="$1" key="$2"
  awk -v section="$section" -v key="$key" '
    function indent_of(s,   n) { n = 0; while (substr(s, n + 1, 1) == " ") n++; return n }
    function clean(line,   first, cpos) {
      sub(/[[:space:]]+$/, "", line)
      first = substr(line, 1, 1)
      if (first == "#") return ""
      if (first == "\"" || first == "\047") {
        cpos = index(substr(line, 2), first)
        if (cpos > 0) return substr(line, 1, cpos + 1)
        return line
      }
      sub(/[[:space:]]#.*$/, "", line)
      sub(/[[:space:]]+$/, "", line)
      return line
    }
    /^[A-Za-z0-9_-]+:/ {
      current = $0
      sub(/:.*/, "", current)
      in_section = (current == section)
      child_indent = -1
      next
    }
    in_section {
      if ($0 ~ /^[[:space:]]*$/) next
      if ($0 ~ /^[[:space:]]*#/) next
      ind = indent_of($0)
      if (child_indent < 0) child_indent = ind
      if (ind == child_indent && $0 ~ "^[[:space:]]+" key ":") {
        line = $0
        sub("^[[:space:]]+" key ":[[:space:]]*", "", line)
        print clean(line)
        exit
      }
    }
  ' "$ALIASES_FILE"
}

# Read one key from a section's nested database: block.
alias_db_value() {
  local section="$1" key="$2"
  awk -v section="$section" -v key="$key" '
    function indent_of(s,   n) { n = 0; while (substr(s, n + 1, 1) == " ") n++; return n }
    function clean(line,   first, cpos) {
      sub(/[[:space:]]+$/, "", line)
      first = substr(line, 1, 1)
      if (first == "#") return ""
      if (first == "\"" || first == "\047") {
        cpos = index(substr(line, 2), first)
        if (cpos > 0) return substr(line, 1, cpos + 1)
        return line
      }
      sub(/[[:space:]]#.*$/, "", line)
      sub(/[[:space:]]+$/, "", line)
      return line
    }
    /^[A-Za-z0-9_-]+:/ {
      current = $0
      sub(/:.*/, "", current)
      in_section = (current == section)
      in_db = 0
      next
    }
    in_section {
      if ($0 ~ /^[[:space:]]*$/) next
      if ($0 ~ /^[[:space:]]*#/) next
      ind = indent_of($0)
      if (in_db && ind <= db_indent) in_db = 0
      if (!in_db && $0 ~ /^[[:space:]]+database:[[:space:]]*(#.*)?$/) {
        in_db = 1
        db_indent = ind
        next
      }
      if (in_db && ind > db_indent && $0 ~ "^[[:space:]]+" key ":") {
        line = $0
        sub("^[[:space:]]+" key ":[[:space:]]*", "", line)
        print clean(line)
        exit
      }
    }
  ' "$ALIASES_FILE"
}

unquote() {
  local value="$1"
  value="${value%\"}"
  value="${value#\"}"
  value="${value%\'}"
  value="${value#\'}"
  printf '%s' "$value"
}

alias_defined() {
  grep -qE "^${1}:" "$ALIASES_FILE"
}

# Validate the alias and load every value the launcher and helpers need
# into globals (ALIAS_*, DB_*_OVERRIDE, PLATFORM, SSH_*, REMOTE_*, ...).
load_alias() {
  local alias="$1"
  [ -f "$ALIASES_FILE" ] || sqlsync_fail "no aliases file found at .ddev/sql-sync/aliases.yml
Create it from the shipped example:
  cp .ddev/sql-sync/aliases.example.yml .ddev/sql-sync/aliases.yml
then fill in your server's host and app path. See the example file for the format."

  case "$alias" in
    ""|*[!A-Za-z0-9_-]*)
      sqlsync_fail "invalid alias name: '@$alias'"
      ;;
  esac

  if ! alias_defined "$alias"; then
    local available
    available="$(grep -oE '^[A-Za-z0-9_-]+:' "$ALIASES_FILE" | tr -d ':' | grep -v '^local$' | paste -sd ' ' - || true)"
    sqlsync_fail "unknown alias '@$alias' in .ddev/sql-sync/aliases.yml (aliases defined: ${available:-none})"
  fi

  # A duplicated alias must never silently resolve to the first definition.
  local defs
  defs="$(grep -cE "^${alias}:" "$ALIASES_FILE")"
  if [ "$defs" -gt 1 ]; then
    sqlsync_fail "alias '@$alias' is defined more than once in .ddev/sql-sync/aliases.yml ($defs definitions) — remove the duplicate; aliases must be unique"
  fi

  ALIAS_HOST="$(unquote "$(alias_value "$alias" host)")"
  ALIAS_USER="$(unquote "$(alias_value "$alias" user)")"
  ALIAS_ROOT="$(unquote "$(alias_value "$alias" root)")"
  ALIAS_TMP="$(unquote "$(alias_value "$alias" tmp)")"
  ALIAS_OPTIONS="$(alias_value "$alias" options)"
  ALIAS_JUMP="$(unquote "$(alias_value "$alias" jump)")"
  PLATFORM="$(unquote "$(alias_value "$alias" platform)")"
  DUMP_CMD="$(unquote "$(alias_value "$alias" dump)")"
  SANITIZE_KEY="$(unquote "$(alias_value "$alias" sanitize)")"
  FILES_DIR="$(unquote "$(alias_value "$alias" files)")"
  LOCAL_DIR="$(unquote "$(alias_value "local" dir)")"
  LOCAL_SNAPSHOT="$(unquote "$(alias_value "local" snapshot)")"
  DB_NAME_OVERRIDE="$(unquote "$(alias_db_value "$alias" name)")"
  DB_USERNAME_OVERRIDE="$(unquote "$(alias_db_value "$alias" username)")"
  DB_PASSWORD_OVERRIDE="$(unquote "$(alias_db_value "$alias" password)")"
  DB_HOST_OVERRIDE="$(unquote "$(alias_db_value "$alias" host)")"
  DB_PORT_OVERRIDE="$(unquote "$(alias_db_value "$alias" port)")"

  [ -n "$ALIAS_HOST" ] || sqlsync_fail "alias '@$alias' in .ddev/sql-sync/aliases.yml is missing the required 'host' key (an ~/.ssh/config alias or a hostname)"
  [ -n "$ALIAS_ROOT" ] || sqlsync_fail "alias '@$alias' in .ddev/sql-sync/aliases.yml is missing the required 'root' key (the app's path on the server)"
  ALIAS_TMP="${ALIAS_TMP:-/tmp}"

  if [ -z "$PLATFORM" ]; then
    local ddev_type=""
    if [ -f "$APPROOT/.ddev/config.yaml" ]; then
      ddev_type="$(grep -E '^type:' "$APPROOT/.ddev/config.yaml" | head -n 1 | sed -E 's/^type:[[:space:]]*//; s/[[:space:]]*$//')" || ddev_type=""
      ddev_type="$(unquote "$ddev_type")"
    fi
    case "$ddev_type" in
      laravel) PLATFORM="laravel" ;;
      wordpress) PLATFORM="wordpress" ;;
      drupal|drupal6|drupal7|drupal8|drupal9|drupal10|drupal11) PLATFORM="drupal" ;;
      *) PLATFORM="php" ;;
    esac
  fi

  case "$PLATFORM" in
    laravel|wordpress|drupal|php) ;;
    *)
      if [ -z "$DUMP_CMD" ]; then
        sqlsync_fail "alias '@$alias' has unknown platform '$PLATFORM' (expected laravel, wordpress, drupal or php — or set a 'dump:' command in the alias, which works for any platform)"
      fi
      ;;
  esac

  SANITIZE_OVERRIDE=""
  if [ -n "$SANITIZE_KEY" ]; then
    case "$SANITIZE_KEY" in
      /*) SANITIZE_OVERRIDE="$SANITIZE_KEY" ;;
      *) SANITIZE_OVERRIDE="$APPROOT/$SANITIZE_KEY" ;;
    esac
    [ -f "$SANITIZE_OVERRIDE" ] || sqlsync_fail "the sanitize file set in alias '@$alias' was not found: $SANITIZE_KEY (looked for $SANITIZE_OVERRIDE)"
  fi

  SSH_TARGET="$ALIAS_HOST"
  [ -n "$ALIAS_USER" ] && SSH_TARGET="$ALIAS_USER@$ALIAS_HOST"
  SSH_OPTIONS="$ALIAS_OPTIONS"
  if [ -n "$ALIAS_JUMP" ]; then
    SSH_OPTIONS="$SSH_OPTIONS -J $ALIAS_JUMP"
  fi
  REMOTE_FILE="$ALIAS_TMP/ddev-dumps/sql-sync.sql"
  REMOTE_DONE="$ALIAS_TMP/ddev-dumps/sql-sync.done"
  REMOTE_ENV="SQL_SYNC_ROOT=$(printf '%q' "$ALIAS_ROOT") SQL_SYNC_TMP=$(printf '%q' "$ALIAS_TMP") SQL_SYNC_PLATFORM=$(printf '%q' "$PLATFORM") SQL_SYNC_DUMP_CMD=$(printf '%q' "$DUMP_CMD") SQL_SYNC_DB_NAME=$(printf '%q' "$DB_NAME_OVERRIDE") SQL_SYNC_DB_USERNAME=$(printf '%q' "$DB_USERNAME_OVERRIDE") SQL_SYNC_DB_PASSWORD=$(printf '%q' "$DB_PASSWORD_OVERRIDE") SQL_SYNC_DB_HOST=$(printf '%q' "$DB_HOST_OVERRIDE") SQL_SYNC_DB_PORT=$(printf '%q' "$DB_PORT_OVERRIDE")"
}

# The local folder downloaded dumps are kept in. $1 is an optional
# --dump-dir override (launcher only).
resolve_dump_dir() {
  local dir="${1:-${LOCAL_DIR:-~/sql-sync}}"
  case "$dir" in
    "~") dir="$HOME" ;;
    "~/"*) dir="$HOME/${dir:2}" ;;
  esac
  printf '%s' "$dir"
}
