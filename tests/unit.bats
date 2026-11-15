#!/usr/bin/env bats
# Fixture-level tests for the v2 (ddev pull) shape. No DDEV, Docker or
# network needed: ssh, rsync and ddev are stubbed on PATH. The ddev stub
# can also emulate `ddev pull` (SQL_SYNC_TEST_PULL_EXEC=1): it reads the
# generated provider file and executes its auth/db_pull/db_import stanzas
# in order, propagating failures the way DDEV does (a failing db_pull
# means the import stanza never runs).
#
# Run with a plain bats-core:  bats ./tests/unit.bats

setup() {
  DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." >/dev/null 2>&1 && pwd)"
}

make_fake_project() {
  FAKE_DIR="$(mktemp -d)"
  STUB_DIR="$(mktemp -d)"
  mkdir -p "${FAKE_DIR}/.ddev/commands/host" "${FAKE_DIR}/.ddev/sql-sync"
  cp "${DIR}/commands/host/sql-sync" "${FAKE_DIR}/.ddev/commands/host/sql-sync"
  cp "${DIR}/sql-sync/"*.sh "${DIR}/sql-sync/sanitize-laravel.sql" "${DIR}/sql-sync/sanitize-wordpress.sql" "${FAKE_DIR}/.ddev/sql-sync/"
  cat > "${STUB_DIR}/ssh" <<'STUBEOF'
#!/usr/bin/env bash
printf 'ssh: %s\n' "$*" >> "${SQL_SYNC_TEST_SSH_CAPTURE}"
if [ -n "${SQL_SYNC_TEST_SSH_FAIL:-}" ]; then
  exit 255
fi
case "$*" in
  *"bash -s"*)
    if [ -n "${SQL_SYNC_TEST_META_PREFIX:-}" ]; then
      echo "sql-sync-meta: wp_prefix=${SQL_SYNC_TEST_META_PREFIX}"
    fi
    ;;
esac
exit 0
STUBEOF
  cat > "${STUB_DIR}/rsync" <<'STUBEOF'
#!/usr/bin/env bash
printf 'rsync: %s\n' "$*" >> "${SQL_SYNC_TEST_RSYNC_CAPTURE}"
eval "src=\${$(( $# - 1 ))}"
eval "dst=\${$#}"
case "$src" in
  *.done)
    if [ -n "${SQL_SYNC_TEST_NO_MARKER:-}" ]; then
      exit 1
    fi
    if [ -n "${SQL_SYNC_TEST_GZIP:-}" ]; then
      sz="$(printf -- '-- fake dump\n' | gzip | wc -c)"
    else
      sz="$(printf -- '-- fake dump\n' | wc -c)"
    fi
    printf '%s\n' "${SQL_SYNC_TEST_MARKER_SIZE:-$sz}" > "$dst"
    ;;
  *.sql)
    if [ -n "${SQL_SYNC_TEST_GZIP:-}" ]; then
      printf -- '-- fake dump\n' | gzip > "$dst"
    else
      printf -- '-- fake dump\n' > "$dst"
    fi
    ;;
esac
exit 0
STUBEOF
  cat > "${STUB_DIR}/ddev" <<'STUBEOF'
#!/usr/bin/env bash
printf 'ddev: %s\n' "$*" >> "${SQL_SYNC_TEST_DDEV_CAPTURE}"
extract_cmd() {
  awk -v stanza="$1" '
    $0 == stanza ":" { in_stanza=1; next }
    in_stanza && /^[^ ]/ { in_stanza=0 }
    in_stanza && /command: \|/ { in_cmd=1; next }
    in_cmd {
      if ($0 ~ /^    /) { print substr($0, 5) } else { in_cmd=0 }
    }
  ' "$2"
}
run_stage() {
  local cmd
  cmd="$(extract_cmd "$1" "$2")"
  [ -z "$cmd" ] && return 0
  DDEV_APPROOT="${SQL_SYNC_TEST_FAKE_DIR}" bash -c "$cmd"
}
case "$1" in
  pull)
    if [ -z "${SQL_SYNC_TEST_PULL_EXEC:-}" ]; then
      exit 0
    fi
    alias_name="$2"
    shift 2
    skip_files=""
    skip_import=""
    for a in "$@"; do
      case "$a" in
        --environment=*) export "${a#--environment=}" ;;
        --skip-files) skip_files=1 ;;
        --skip-import) skip_import=1 ;;
      esac
    done
    provider="${SQL_SYNC_TEST_FAKE_DIR}/.ddev/providers/${alias_name}.yaml"
    [ -f "$provider" ] || { echo "stub pull: no provider $provider" >&2; exit 1; }
    run_stage auth_command "$provider" || exit $?
    run_stage db_pull_command "$provider" || exit $?
    if [ -z "$skip_import" ]; then
      run_stage db_import_command "$provider" || exit $?
    fi
    if [ -z "$skip_files" ]; then
      run_stage files_pull_command "$provider" || exit $?
    fi
    ;;
  import-db*)
    if [ -n "${SQL_SYNC_TEST_IMPORT_FAIL:-}" ]; then
      exit 1
    fi
    ;;
  drush)
    if [ "$2" = "--version" ] && [ -n "${SQL_SYNC_TEST_NO_DRUSH:-}" ]; then
      exit 1
    fi
    ;;
  mysql)
    if [ "$#" -eq 1 ]; then
      cat > "${SQL_SYNC_TEST_SANITIZE_CAPTURE}"
      exit 0
    fi
    sql=""
    prev=""
    for a in "$@"; do
      if [ "$prev" = "-e" ]; then sql="$a"; fi
      prev="$a"
    done
    case "$sql" in
      "SHOW TABLES;")
        for t in ${SQL_SYNC_TEST_TABLES:-}; do echo "$t"; done
        ;;
      *"SHOW TABLES LIKE '"*)
        t="$(printf '%s' "$sql" | sed -E "s/^SHOW TABLES LIKE '//; s/';$//")"
        for x in ${SQL_SYNC_TEST_TABLES:-}; do
          if [ "$x" = "$t" ]; then echo "$t"; fi
        done
        ;;
    esac
    ;;
esac
exit 0
STUBEOF
  chmod +x "${STUB_DIR}/ssh" "${STUB_DIR}/rsync" "${STUB_DIR}/ddev"
  export SQL_SYNC_TEST_FAKE_DIR="${FAKE_DIR}"
  export SQL_SYNC_TEST_SSH_CAPTURE="${FAKE_DIR}/ssh-capture.txt"
  export SQL_SYNC_TEST_RSYNC_CAPTURE="${FAKE_DIR}/rsync-capture.txt"
  export SQL_SYNC_TEST_DDEV_CAPTURE="${FAKE_DIR}/ddev-capture.txt"
  export SQL_SYNC_TEST_SANITIZE_CAPTURE="${FAKE_DIR}/sanitize-capture.sql"
  export TEST_PATH="${STUB_DIR}:/usr/bin:/bin"
  export TEST_HOME="${FAKE_DIR}/home"
  mkdir -p "${TEST_HOME}"
}

write_aliases() {
  cat > "${FAKE_DIR}/.ddev/sql-sync/aliases.yml"
}

@test "launcher: argument validation (@self required, non-@self and unknown alias rejected)" {
  make_fake_project
  write_aliases <<'EOF'
prod:
  host: app.example.com
  user: deploy
  root: /var/www/example
EOF
  run env HOME="${TEST_HOME}" PATH="${TEST_PATH}" bash "${FAKE_DIR}/.ddev/commands/host/sql-sync" @prod -y
  [ "$status" -ne 0 ]
  [[ "$output" == *"a target is required"* ]]
  run env HOME="${TEST_HOME}" PATH="${TEST_PATH}" bash "${FAKE_DIR}/.ddev/commands/host/sql-sync" @prod @staging -y
  [ "$status" -ne 0 ]
  [[ "$output" == *"only @self is supported"* ]]
  run env HOME="${TEST_HOME}" PATH="${TEST_PATH}" bash "${FAKE_DIR}/.ddev/commands/host/sql-sync" @nope @self -y
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown alias"* ]]
  [ ! -e "${SQL_SYNC_TEST_DDEV_CAPTURE}" ]
}

@test "launcher: duplicate alias is a hard error" {
  make_fake_project
  write_aliases <<'EOF'
prod:
  host: first.example.com
  root: /var/www/first
prod:
  host: second.example.com
  root: /var/www/second
EOF
  run env HOME="${TEST_HOME}" PATH="${TEST_PATH}" bash "${FAKE_DIR}/.ddev/commands/host/sql-sync" @prod @self -y
  [ "$status" -ne 0 ]
  [[ "$output" == *"defined more than once"* ]]
}

@test "launcher: provider generation matches the golden file and contains no secret" {
  make_fake_project
  write_aliases <<'EOF'
prod:
  host: app.example.com
  user: deploy
  root: /var/www/example
  platform: laravel
  database:
    name: appdb
    username: appuser
    password: "sup3r-secret-pin"
EOF
  run env HOME="${TEST_HOME}" PATH="${TEST_PATH}" bash "${FAKE_DIR}/.ddev/commands/host/sql-sync" @prod @self -y
  [ "$status" -eq 0 ]
  run diff -u "${DIR}/tests/testdata/provider-prod.yaml.golden" "${FAKE_DIR}/.ddev/providers/prod.yaml"
  [ "$status" -eq 0 ]
  run grep -c "sup3r-secret-pin" "${FAKE_DIR}/.ddev/providers/prod.yaml"
  [ "$status" -ne 0 ]
  run cat "${SQL_SYNC_TEST_DDEV_CAPTURE}"
  [[ "$output" == *"ddev: pull prod --skip-files -y"* ]]
}

@test "launcher: files alias drops --skip-files, sanitize/no-dump/dump-dir travel via --environment" {
  make_fake_project
  write_aliases <<'EOF'
prod:
  host: app.example.com
  user: deploy
  root: /var/www/example
  platform: laravel
  files: /var/www/example/uploads
EOF
  run env HOME="${TEST_HOME}" PATH="${TEST_PATH}" bash "${FAKE_DIR}/.ddev/commands/host/sql-sync" @prod @self -y --no-sanitize --no-dump --dump-dir=/tmp/kept
  [ "$status" -eq 0 ]
  run cat "${SQL_SYNC_TEST_DDEV_CAPTURE}"
  [[ "$output" == *"ddev: pull prod --environment=SQL_SYNC_SANITIZE=false --environment=SQL_SYNC_NO_DUMP=1 --environment=SQL_SYNC_DUMP_DIR=/tmp/kept -y"* ]]
  run grep -c "files_pull_command" "${FAKE_DIR}/.ddev/providers/prod.yaml"
  [[ "$output" == "1" ]]
}

@test "launcher: local snapshot opt-in snapshots before the pull" {
  make_fake_project
  write_aliases <<'EOF'
local:
  dir: ~/sql-sync
  snapshot: true
prod:
  host: app.example.com
  user: deploy
  root: /var/www/example
EOF
  run env HOME="${TEST_HOME}" PATH="${TEST_PATH}" bash "${FAKE_DIR}/.ddev/commands/host/sql-sync" @prod @self -y
  [ "$status" -eq 0 ]
  run grep -n "snapshot --name=sql-sync-prod-" "${SQL_SYNC_TEST_DDEV_CAPTURE}"
  [ "$status" -eq 0 ]
  snap_line="${output%%:*}"
  run grep -n "pull prod" "${SQL_SYNC_TEST_DDEV_CAPTURE}"
  pull_line="${output%%:*}"
  [ "$snap_line" -lt "$pull_line" ]
}

@test "launcher: --dry-run stays launcher-side (no pull, no rsync)" {
  make_fake_project
  write_aliases <<EOF
local:
  dir: ${FAKE_DIR}/dumps
prod:
  host: app.example.com
  user: deploy
  root: /var/www/example
EOF
  run env HOME="${TEST_HOME}" PATH="${TEST_PATH}" bash "${FAKE_DIR}/.ddev/commands/host/sql-sync" @prod @self --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"preflight: ok: ssh connectivity"* ]]
  [[ "$output" == *"No dump was taken, nothing was imported"* ]]
  [ ! -e "${SQL_SYNC_TEST_RSYNC_CAPTURE}" ]
  [ ! -e "${SQL_SYNC_TEST_DDEV_CAPTURE}" ]
  [ ! -e "${FAKE_DIR}/.ddev/providers/prod.yaml" ]
}

@test "launcher: --no-sync stays launcher-side (dump only, no pull)" {
  make_fake_project
  write_aliases <<'EOF'
prod:
  host: app.example.com
  user: deploy
  root: /var/www/example
EOF
  run env HOME="${TEST_HOME}" PATH="${TEST_PATH}" bash "${FAKE_DIR}/.ddev/commands/host/sql-sync" @prod @self --no-sync
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing downloaded or imported"* ]]
  [ ! -e "${SQL_SYNC_TEST_RSYNC_CAPTURE}" ]
  [ ! -e "${SQL_SYNC_TEST_DDEV_CAPTURE}" ]
}

@test "auth-check: BatchMode ssh check passes and fails with the stub" {
  make_fake_project
  write_aliases <<'EOF'
prod:
  host: app.example.com
  user: deploy
  root: /var/www/example
EOF
  run env HOME="${TEST_HOME}" PATH="${TEST_PATH}" bash "${FAKE_DIR}/.ddev/sql-sync/auth-check.sh" prod
  [ "$status" -eq 0 ]
  run cat "${SQL_SYNC_TEST_SSH_CAPTURE}"
  [[ "$output" == *"BatchMode=yes"* ]]
  [[ "$output" == *"deploy@app.example.com true"* ]]
  run env HOME="${TEST_HOME}" SQL_SYNC_TEST_SSH_FAIL=1 PATH="${TEST_PATH}" bash "${FAKE_DIR}/.ddev/sql-sync/auth-check.sh" prod
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot reach"* ]]
}

@test "auth-check: quoted options reach ssh without the quotes" {
  make_fake_project
  write_aliases <<'EOF'
prod:
  host: app.example.com
  user: deploy
  root: /var/www/example
  options: "-p 2223 -i ~/.ssh/testkey"
EOF
  run env HOME="${TEST_HOME}" PATH="${TEST_PATH}" bash "${FAKE_DIR}/.ddev/sql-sync/auth-check.sh" prod
  [ "$status" -eq 0 ]
  run cat "${SQL_SYNC_TEST_SSH_CAPTURE}"
  [[ "$output" == *"-p 2223 -i ~/.ssh/testkey"* ]]
  [[ "$output" != *'"-p'* ]]
}

@test "install: every project file in install.yaml carries the #ddev-generated signature" {
  files="$(awk '/^project_files:/{f=1; next} f && /^  - /{print $2} f && /^[^ ]/{f=0}' "${DIR}/install.yaml")"
  [ -n "$files" ]
  for f in $files; do
    run grep -q '#ddev-generated' "${DIR}/${f}"
    [ "$status" -eq 0 ] || { echo "missing #ddev-generated signature: $f"; return 1; }
  done
}

@test "pull-db: happy path verifies, normalises to db.sql.gz, keeps a copy, writes state" {
  make_fake_project
  write_aliases <<EOF
local:
  dir: ${FAKE_DIR}/dumps
prod:
  host: app.example.com
  user: deploy
  root: /var/www/example
  platform: wordpress
EOF
  run env HOME="${TEST_HOME}" SQL_SYNC_TEST_META_PREFIX="site_" PATH="${TEST_PATH}" bash "${FAKE_DIR}/.ddev/sql-sync/pull-db.sh" prod
  [ "$status" -eq 0 ]
  [[ "$output" == *"verified:"* ]]
  [ -f "${FAKE_DIR}/.ddev/.downloads/db.sql.gz" ]
  run gzip -dc "${FAKE_DIR}/.ddev/.downloads/db.sql.gz"
  [[ "$output" == *"-- fake dump"* ]]
  [ -f "${FAKE_DIR}/dumps/prod.sql" ]
  run cat "${FAKE_DIR}/.ddev/sql-sync/.state/prod.env"
  [[ "$output" == *"PLATFORM=wordpress"* ]]
  [[ "$output" == *"WP_PREFIX=site_"* ]]
  [[ "$output" == *"SANITIZE=true"* ]]
  run cat "${SQL_SYNC_TEST_SSH_CAPTURE}"
  [[ "$output" == *"bash -s"* ]]
}

@test "pull-db: marker mismatch and missing marker refuse before any import artefact" {
  make_fake_project
  write_aliases <<EOF
local:
  dir: ${FAKE_DIR}/dumps
prod:
  host: app.example.com
  user: deploy
  root: /var/www/example
  platform: laravel
EOF
  run env HOME="${TEST_HOME}" SQL_SYNC_TEST_MARKER_SIZE=999999 PATH="${TEST_PATH}" bash "${FAKE_DIR}/.ddev/sql-sync/pull-db.sh" prod
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing to import"* ]]
  [ ! -e "${FAKE_DIR}/.ddev/.downloads/db.sql.gz" ]
  [ ! -e "${FAKE_DIR}/.ddev/sql-sync/.state/prod.env" ]
  run env HOME="${TEST_HOME}" SQL_SYNC_TEST_NO_MARKER=1 PATH="${TEST_PATH}" bash "${FAKE_DIR}/.ddev/sql-sync/pull-db.sh" prod
  [ "$status" -ne 0 ]
  [[ "$output" == *"completion marker"* ]]
  [ ! -e "${FAKE_DIR}/.ddev/.downloads/db.sql.gz" ]
}

@test "pull-db: SQL_SYNC_NO_DUMP skips dump creation but still downloads" {
  make_fake_project
  write_aliases <<EOF
local:
  dir: ${FAKE_DIR}/dumps
prod:
  host: app.example.com
  user: deploy
  root: /var/www/example
  platform: laravel
EOF
  run env HOME="${TEST_HOME}" SQL_SYNC_NO_DUMP=1 PATH="${TEST_PATH}" bash "${FAKE_DIR}/.ddev/sql-sync/pull-db.sh" prod
  [ "$status" -eq 0 ]
  [ ! -e "${SQL_SYNC_TEST_SSH_CAPTURE}" ]
  [ -f "${FAKE_DIR}/.ddev/.downloads/db.sql.gz" ]
}

@test "pull-db: gzipped dump is kept as .sql.gz" {
  make_fake_project
  write_aliases <<EOF
local:
  dir: ${FAKE_DIR}/dumps
prod:
  host: app.example.com
  user: deploy
  root: /var/www/example
  platform: laravel
EOF
  run env HOME="${TEST_HOME}" SQL_SYNC_TEST_GZIP=1 PATH="${TEST_PATH}" bash "${FAKE_DIR}/.ddev/sql-sync/pull-db.sh" prod
  [ "$status" -eq 0 ]
  [ -f "${FAKE_DIR}/dumps/prod.sql.gz" ]
  run gzip -dc "${FAKE_DIR}/.ddev/.downloads/db.sql.gz"
  [[ "$output" == *"-- fake dump"* ]]
}

@test "import-db: laravel sanitize runs and remote cleanup follows success" {
  make_fake_project
  write_aliases <<EOF
local:
  dir: ${FAKE_DIR}/dumps
prod:
  host: app.example.com
  user: deploy
  root: /var/www/example
  platform: laravel
EOF
  run env HOME="${TEST_HOME}" PATH="${TEST_PATH}" bash "${FAKE_DIR}/.ddev/sql-sync/pull-db.sh" prod
  [ "$status" -eq 0 ]
  run env HOME="${TEST_HOME}" SQL_SYNC_TEST_TABLES="users" PATH="${TEST_PATH}" bash "${FAKE_DIR}/.ddev/sql-sync/import-db.sh" prod
  [ "$status" -eq 0 ]
  run cat "${SQL_SYNC_TEST_SANITIZE_CAPTURE}"
  [[ "$output" == *'UPDATE `users`'* ]]
  run grep -c "rm -f" "${SQL_SYNC_TEST_SSH_CAPTURE}"
  [[ "$output" == "1" ]]
}

@test "import-db: sanitize gate fails the stage and keeps the remote dump" {
  make_fake_project
  write_aliases <<EOF
local:
  dir: ${FAKE_DIR}/dumps
prod:
  host: app.example.com
  user: deploy
  root: /var/www/example
EOF
  run env HOME="${TEST_HOME}" PATH="${TEST_PATH}" bash "${FAKE_DIR}/.ddev/sql-sync/pull-db.sh" prod
  [ "$status" -eq 0 ]
  run env HOME="${TEST_HOME}" PATH="${TEST_PATH}" bash "${FAKE_DIR}/.ddev/sql-sync/import-db.sh" prod
  [ "$status" -ne 0 ]
  [[ "$output" == *"completed WITHOUT sanitize"* ]]
  run grep "rm -f" "${SQL_SYNC_TEST_SSH_CAPTURE}"
  [ "$status" -ne 0 ]
}

@test "import-db: failed import keeps the remote dump" {
  make_fake_project
  write_aliases <<EOF
local:
  dir: ${FAKE_DIR}/dumps
prod:
  host: app.example.com
  user: deploy
  root: /var/www/example
  platform: laravel
EOF
  run env HOME="${TEST_HOME}" PATH="${TEST_PATH}" bash "${FAKE_DIR}/.ddev/sql-sync/pull-db.sh" prod
  [ "$status" -eq 0 ]
  run env HOME="${TEST_HOME}" SQL_SYNC_TEST_IMPORT_FAIL=1 PATH="${TEST_PATH}" bash "${FAKE_DIR}/.ddev/sql-sync/import-db.sh" prod
  [ "$status" -ne 0 ]
  [[ "$output" == *"kept on the server"* ]]
  run grep "rm -f" "${SQL_SYNC_TEST_SSH_CAPTURE}"
  [ "$status" -ne 0 ]
}

@test "import-db: sanitize=false recorded at pull stage skips sanitize and still cleans up" {
  make_fake_project
  write_aliases <<EOF
local:
  dir: ${FAKE_DIR}/dumps
prod:
  host: app.example.com
  user: deploy
  root: /var/www/example
EOF
  run env HOME="${TEST_HOME}" SQL_SYNC_SANITIZE=false PATH="${TEST_PATH}" bash "${FAKE_DIR}/.ddev/sql-sync/pull-db.sh" prod
  [ "$status" -eq 0 ]
  run env HOME="${TEST_HOME}" PATH="${TEST_PATH}" bash "${FAKE_DIR}/.ddev/sql-sync/import-db.sh" prod
  [ "$status" -eq 0 ]
  [[ "$output" == *"SKIPPED (--no-sanitize)"* ]]
  run grep -c "rm -f" "${SQL_SYNC_TEST_SSH_CAPTURE}"
  [[ "$output" == "1" ]]
}

@test "emulated pull: launcher runs the full obtain+import through the provider" {
  make_fake_project
  write_aliases <<EOF
local:
  dir: ${FAKE_DIR}/dumps
prod:
  host: app.example.com
  user: deploy
  root: /var/www/example
  platform: laravel
  jump: bastion.example.com
EOF
  run env HOME="${TEST_HOME}" SQL_SYNC_TEST_PULL_EXEC=1 SQL_SYNC_TEST_TABLES="users" PATH="${TEST_PATH}" bash "${FAKE_DIR}/.ddev/commands/host/sql-sync" @prod @self -y
  [ "$status" -eq 0 ]
  run cat "${SQL_SYNC_TEST_DDEV_CAPTURE}"
  [[ "$output" == *"import-db"* ]]
  run cat "${SQL_SYNC_TEST_SANITIZE_CAPTURE}"
  [[ "$output" == *'UPDATE `users`'* ]]
  run grep -c -- "-J bastion.example.com" "${SQL_SYNC_TEST_SSH_CAPTURE}"
  [[ "$output" == "3" ]]
  [ -f "${FAKE_DIR}/dumps/prod.sql" ]
  [ -f "${FAKE_DIR}/.ddev/.downloads/db.sql.gz" ]
}

@test "emulated pull: a marker mismatch in db_pull gates the import stage" {
  make_fake_project
  write_aliases <<EOF
local:
  dir: ${FAKE_DIR}/dumps
prod:
  host: app.example.com
  user: deploy
  root: /var/www/example
  platform: laravel
EOF
  run env HOME="${TEST_HOME}" SQL_SYNC_TEST_PULL_EXEC=1 SQL_SYNC_TEST_MARKER_SIZE=999999 SQL_SYNC_TEST_TABLES="users" PATH="${TEST_PATH}" bash "${FAKE_DIR}/.ddev/commands/host/sql-sync" @prod @self -y
  [ "$status" -ne 0 ]
  run grep "import-db" "${SQL_SYNC_TEST_DDEV_CAPTURE}"
  [ "$status" -ne 0 ]
}


@test "pull-db: platform resolution falls back to the DDEV type, then php" {
  make_fake_project
  write_aliases <<EOF
local:
  dir: ${FAKE_DIR}/dumps
prod:
  host: app.example.com
  user: deploy
  root: /var/www/example
EOF
  printf 'type: laravel\n' > "${FAKE_DIR}/.ddev/config.yaml"
  run env HOME="${TEST_HOME}" PATH="${TEST_PATH}" bash "${FAKE_DIR}/.ddev/sql-sync/pull-db.sh" prod
  [ "$status" -eq 0 ]
  run cat "${SQL_SYNC_TEST_SSH_CAPTURE}"
  [[ "$output" == *"SQL_SYNC_PLATFORM=laravel"* ]]
  printf 'type: backdrop\n' > "${FAKE_DIR}/.ddev/config.yaml"
  rm -f "${SQL_SYNC_TEST_SSH_CAPTURE}"
  run env HOME="${TEST_HOME}" PATH="${TEST_PATH}" bash "${FAKE_DIR}/.ddev/sql-sync/pull-db.sh" prod
  [ "$status" -eq 0 ]
  run cat "${SQL_SYNC_TEST_SSH_CAPTURE}"
  [[ "$output" == *"SQL_SYNC_PLATFORM=php"* ]]
}

@test "pull-db: inline comments on every key, full remote environment reaches ssh" {
  make_fake_project
  write_aliases <<'EOF'
prod:
  host: myserver # the office server
  user: deploy # ssh user
  root: /var/www/example # app path
  tmp: /tmp # temp folder
  platform: laravel # the platform
  jump: bastion.example.com # the bastion
  database: # credentials
    name: appdb # db name
    username: appuser # db user
    password: "pa#ss" # db password
    host: db.internal # db host
    port: 3307 # db port
EOF
  run env HOME="${TEST_HOME}" PATH="${TEST_PATH}" bash "${FAKE_DIR}/.ddev/sql-sync/pull-db.sh" prod
  [ "$status" -eq 0 ]
  run cat "${SQL_SYNC_TEST_SSH_CAPTURE}"
  [[ "$output" == *"deploy@myserver"* ]]
  [[ "$output" == *"SQL_SYNC_PLATFORM=laravel"* ]]
  [[ "$output" == *"SQL_SYNC_DB_PASSWORD=pa#ss"* ]]
  [[ "$output" == *"SQL_SYNC_DB_PORT=3307"* ]]
  [[ "$output" == *"-J bastion.example.com"* ]]
}

@test "import-db: wordpress prefix from pull state, drupal drush, alias sanitize file wins" {
  make_fake_project
  write_aliases <<EOF
local:
  dir: ${FAKE_DIR}/dumps
prod:
  host: app.example.com
  user: deploy
  root: /var/www/example
  platform: wordpress
EOF
  run env HOME="${TEST_HOME}" SQL_SYNC_TEST_META_PREFIX="site_" PATH="${TEST_PATH}" bash "${FAKE_DIR}/.ddev/sql-sync/pull-db.sh" prod
  [ "$status" -eq 0 ]
  run env HOME="${TEST_HOME}" SQL_SYNC_TEST_TABLES="site_users site_options" PATH="${TEST_PATH}" bash "${FAKE_DIR}/.ddev/sql-sync/import-db.sh" prod
  [ "$status" -eq 0 ]
  run cat "${SQL_SYNC_TEST_SANITIZE_CAPTURE}"
  [[ "$output" == *'UPDATE `site_users`'* ]]

  write_aliases <<EOF
local:
  dir: ${FAKE_DIR}/dumps
prod:
  host: app.example.com
  user: deploy
  root: /var/www/example
  platform: drupal
EOF
  run env HOME="${TEST_HOME}" PATH="${TEST_PATH}" bash "${FAKE_DIR}/.ddev/sql-sync/pull-db.sh" prod
  [ "$status" -eq 0 ]
  rm -f "${SQL_SYNC_TEST_DDEV_CAPTURE}"
  run env HOME="${TEST_HOME}" PATH="${TEST_PATH}" bash "${FAKE_DIR}/.ddev/sql-sync/import-db.sh" prod
  [ "$status" -eq 0 ]
  run cat "${SQL_SYNC_TEST_DDEV_CAPTURE}"
  [[ "$output" == *"drush sql-sanitize"* ]]

  printf -- '-- custom sanitize\nUPDATE users SET email = "x";\n' > "${FAKE_DIR}/my-sanitize.sql"
  write_aliases <<EOF
local:
  dir: ${FAKE_DIR}/dumps
prod:
  host: app.example.com
  user: deploy
  root: /var/www/example
  platform: drupal
  sanitize: my-sanitize.sql
EOF
  run env HOME="${TEST_HOME}" PATH="${TEST_PATH}" bash "${FAKE_DIR}/.ddev/sql-sync/pull-db.sh" prod
  [ "$status" -eq 0 ]
  rm -f "${SQL_SYNC_TEST_DDEV_CAPTURE}" "${SQL_SYNC_TEST_SANITIZE_CAPTURE}"
  run env HOME="${TEST_HOME}" PATH="${TEST_PATH}" bash "${FAKE_DIR}/.ddev/sql-sync/import-db.sh" prod
  [ "$status" -eq 0 ]
  run cat "${SQL_SYNC_TEST_SANITIZE_CAPTURE}"
  [[ "$output" == *"UPDATE users SET email"* ]]
  run grep "drush sql-sanitize" "${SQL_SYNC_TEST_DDEV_CAPTURE}"
  [ "$status" -ne 0 ]
}

@test "launcher: the shipped example file works verbatim (record mode)" {
  make_fake_project
  cp "${DIR}/sql-sync/aliases.example.yml" "${FAKE_DIR}/.ddev/sql-sync/aliases.yml"
  run env HOME="${TEST_HOME}" PATH="${TEST_PATH}" bash "${FAKE_DIR}/.ddev/commands/host/sql-sync" @prod @self -y --no-sanitize
  [ "$status" -eq 0 ]
  [[ "$output" == *"dump file: ${TEST_HOME}/sql-sync/prod.sql"* ]]
  run cat "${SQL_SYNC_TEST_DDEV_CAPTURE}"
  [[ "$output" == *"pull prod"* ]]
}
