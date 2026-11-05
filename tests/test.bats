#!/usr/bin/env bats

# Bats is a testing framework for Bash
# Documentation https://bats-core.readthedocs.io/en/stable/
# Bats libraries documentation https://github.com/ztombol/bats-docs

# For local tests, install bats-core, bats-assert, bats-file, bats-support
# And run this in the add-on root directory:
#   bats ./tests/test.bats
# To exclude release tests:
#   bats ./tests/test.bats --filter-tags '!release'
# For debugging:
#   bats ./tests/test.bats --show-output-of-passing-tests --verbose-run --print-output-on-failure

setup() {
  set -eu -o pipefail
  export GITHUB_REPO=atj4me/ddev-sql-sync

  TEST_BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"
  export BATS_LIB_PATH="${BATS_LIB_PATH}:${TEST_BREW_PREFIX}/lib:/usr/lib/bats"
  bats_load_library bats-assert
  bats_load_library bats-file
  bats_load_library bats-support

  export DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." >/dev/null 2>&1 && pwd)"
  export PROJNAME="test-$(basename "${GITHUB_REPO}")"
  mkdir -p ~/tmp
  export TESTDIR=$(mktemp -d ~/tmp/${PROJNAME}.XXXXXX)
  export DDEV_NONINTERACTIVE=true
  export DDEV_NO_INSTRUMENTATION=true
  export CI=true

  # Clean up any existing project
  ddev delete -Oy "${PROJNAME}" >/dev/null 2>&1 || true
  cd "${TESTDIR}"

  # Configure and start DDEV project
  run ddev config --project-name="${PROJNAME}" --project-tld=ddev.site
  assert_success
  run ddev start -y
  assert_success
}

health_checks() {
  # Check if DDEV is running properly
  run ddev describe -j
  assert_success

  # Check if web service is running
  run bash -c "ddev describe -j | jq -r '.raw.services.web.State.Status'"
  assert_success
  assert_output "running"
}

teardown() {
  set -eu -o pipefail

  # Clean up DDEV project
  ddev delete -Oy ${PROJNAME} >/dev/null 2>&1 || true

  # Persist TESTDIR if running inside GitHub Actions
  if [ -n "${GITHUB_ENV:-}" ]; then
    [ -e "${GITHUB_ENV:-}" ] && echo "TESTDIR=${HOME}/tmp/${PROJNAME}" >> "${GITHUB_ENV}"
  else
    [ "${TESTDIR}" != "" ] && rm -rf "${TESTDIR}"
  fi
}

# A mysqldump stand-in that records its arguments and MYSQL_PWD so tests can
# assert exactly which credentials remote-dump.sh resolved.
make_stub_mysqldump() {
  STUB_DIR="$(mktemp -d)"
  cat > "${STUB_DIR}/mysqldump" <<'STUBEOF'
#!/usr/bin/env bash
if [ -n "${SQL_SYNC_TEST_CAPTURE:-}" ]; then
  printf 'args: %s\npw: %s\n' "$*" "${MYSQL_PWD:-}" > "${SQL_SYNC_TEST_CAPTURE}"
fi
echo "-- fake mysqldump output"
if [ -n "${SQL_SYNC_TEST_DUMP_FAIL:-}" ]; then
  echo "-- partial output before dying"
  exit 3
fi
STUBEOF
  chmod +x "${STUB_DIR}/mysqldump"
}

@test "install from directory" {
  set -eu -o pipefail
  echo "# ddev add-on get ${DIR} with project ${PROJNAME} in $(pwd)" >&3

  run ddev add-on get "${DIR}"
  assert_success

  assert_file_exist .ddev/commands/host/sql-sync
  assert_file_exist .ddev/sql-sync/remote-dump.sh
  assert_file_exist .ddev/sql-sync/sanitize-laravel.sql
  assert_file_exist .ddev/sql-sync/sanitize-wordpress.sql
  assert_file_exist .ddev/sql-sync/aliases.example.yml
  # Post-install copies the example to the user's own aliases.yml
  assert_file_exist .ddev/sql-sync/aliases.yml
  # ...and the copy must not describe itself as the example file
  run head -n 1 .ddev/sql-sync/aliases.yml
  assert_output --partial "is yours"
  refute_output --partial "example file is managed"

  run ddev restart -y
  assert_success
  refute_output --partial "ERROR (spawn error)"
}

@test "sql-sync help and error paths" {
  set -eu -o pipefail

  run ddev add-on get "${DIR}"
  assert_success

  run ddev sql-sync --help
  assert_success
  assert_output --partial "Usage: ddev sql-sync"

  # A non-@self target is rejected before anything else happens
  run ddev sql-sync @prod @staging -y
  assert_failure
  assert_output --partial "@self"

  # A missing target is rejected: source AND destination, always
  run ddev sql-sync @prod -y
  assert_failure
  assert_output --partial "a target is required"

  # Unknown alias fails before any ssh attempt
  run ddev sql-sync @nope @self -y
  assert_failure
  assert_output --partial "unknown alias"

  # Missing aliases.yml fails with instructions
  rm .ddev/sql-sync/aliases.yml
  run ddev sql-sync @prod @self -y
  assert_failure
  assert_output --partial "aliases.yml"
}

@test "remote dump: credentials from .env fixture (mysqldump strategy)" {
  set -eu -o pipefail
  make_stub_mysqldump
  FIXTURE_DIR="$(mktemp -d)"
  cat > "${FIXTURE_DIR}/.env" <<'FIXEOF'
DB_DATABASE=fixturedb
DB_USERNAME=fixtureuser
DB_PASSWORD=fixturepass
DB_HOST=127.0.0.1
FIXEOF
  export SQL_SYNC_TEST_CAPTURE="${FIXTURE_DIR}/capture.txt"
  run env PATH="${STUB_DIR}:/usr/bin:/bin" SQL_SYNC_ROOT="${FIXTURE_DIR}" SQL_SYNC_TMP="${FIXTURE_DIR}" SQL_SYNC_PLATFORM=laravel bash "${DIR}/sql-sync/remote-dump.sh"
  assert_success
  assert_output --partial "using mysqldump"
  run cat "${SQL_SYNC_TEST_CAPTURE}"
  assert_output --partial "args: -h 127.0.0.1 -u fixtureuser"
  assert_output --partial "fixturedb"
  assert_output --partial "pw: fixturepass"
}

@test "remote dump: database overrides merge over .env field by field" {
  set -eu -o pipefail
  make_stub_mysqldump
  FIXTURE_DIR="$(mktemp -d)"
  # No DB_PASSWORD here, and a localhost DB_HOST: both are overridden below,
  # while name and username fall back to this .env.
  cat > "${FIXTURE_DIR}/.env" <<'FIXEOF'
DB_DATABASE=mergedb
DB_USERNAME=mergeuser
DB_HOST=localhost
FIXEOF
  export SQL_SYNC_TEST_CAPTURE="${FIXTURE_DIR}/capture.txt"
  run env PATH="${STUB_DIR}:/usr/bin:/bin" SQL_SYNC_ROOT="${FIXTURE_DIR}" SQL_SYNC_TMP="${FIXTURE_DIR}" SQL_SYNC_PLATFORM=laravel SQL_SYNC_DB_PASSWORD=override-pass SQL_SYNC_DB_HOST=db.internal.example SQL_SYNC_DB_PORT=3307 bash "${DIR}/sql-sync/remote-dump.sh"
  assert_success
  run cat "${SQL_SYNC_TEST_CAPTURE}"
  assert_output --partial "args: -h db.internal.example -P 3307 -u mergeuser"
  assert_output --partial "mergedb"
  assert_output --partial "pw: override-pass"
}

@test "remote dump: wp-config fixture, mysqldump when wp-cli is absent" {
  set -eu -o pipefail
  make_stub_mysqldump
  FIXTURE_DIR="$(mktemp -d)"
  cat > "${FIXTURE_DIR}/wp-config.php" <<'FIXEOF'
<?php
define( 'DB_NAME', 'wpdb' );
define( 'DB_USER', 'wpuser' );
define( 'DB_PASSWORD', 'wppass' );
define( 'DB_HOST', 'localhost' );
FIXEOF
  export SQL_SYNC_TEST_CAPTURE="${FIXTURE_DIR}/capture.txt"
  run env PATH="${STUB_DIR}:/usr/bin:/bin" SQL_SYNC_ROOT="${FIXTURE_DIR}" SQL_SYNC_TMP="${FIXTURE_DIR}" SQL_SYNC_PLATFORM=wordpress bash "${DIR}/sql-sync/remote-dump.sh"
  assert_success
  assert_output --partial "using mysqldump"
  run cat "${SQL_SYNC_TEST_CAPTURE}"
  assert_output --partial "args: -u wpuser"
  assert_output --partial "wpdb"
  assert_output --partial "pw: wppass"
}

@test "remote dump: wp-cli export wins when wp is available" {
  set -eu -o pipefail
  STUB_DIR="$(mktemp -d)"
  cat > "${STUB_DIR}/wp" <<'STUBEOF'
#!/usr/bin/env bash
for last; do :; done
echo "-- wp-cli stub dump" > "$last"
STUBEOF
  chmod +x "${STUB_DIR}/wp"
  FIXTURE_DIR="$(mktemp -d)"
  cat > "${FIXTURE_DIR}/wp-config.php" <<'FIXEOF'
<?php
define( 'DB_NAME', 'wpdb' );
define( 'DB_USER', 'wpuser' );
define( 'DB_PASSWORD', 'wppass' );
define( 'DB_HOST', 'localhost' );
FIXEOF
  run env PATH="${STUB_DIR}:/usr/bin:/bin" SQL_SYNC_ROOT="${FIXTURE_DIR}" SQL_SYNC_TMP="${FIXTURE_DIR}" SQL_SYNC_PLATFORM=wordpress bash "${DIR}/sql-sync/remote-dump.sh"
  assert_success
  assert_output --partial "wp db export"
  run grep -c "wp-cli stub dump" "${FIXTURE_DIR}/ddev-dumps/sql-sync.sql"
  assert_success
  assert_output "1"
}

@test "remote dump: dump command wins over app export and mysqldump" {
  set -eu -o pipefail
  make_stub_mysqldump
  cat > "${STUB_DIR}/wp" <<'STUBEOF'
#!/usr/bin/env bash
for last; do :; done
echo "-- wp-cli stub dump" > "$last"
STUBEOF
  chmod +x "${STUB_DIR}/wp"
  FIXTURE_DIR="$(mktemp -d)"
  cat > "${FIXTURE_DIR}/wp-config.php" <<'FIXEOF'
<?php
define( 'DB_NAME', 'wpdb' );
define( 'DB_USER', 'wpuser' );
define( 'DB_PASSWORD', 'wppass' );
define( 'DB_HOST', 'localhost' );
FIXEOF
  export SQL_SYNC_TEST_CAPTURE="${FIXTURE_DIR}/capture.txt"
  run env PATH="${STUB_DIR}:/usr/bin:/bin" SQL_SYNC_ROOT="${FIXTURE_DIR}" SQL_SYNC_TMP="${FIXTURE_DIR}" SQL_SYNC_PLATFORM=wordpress SQL_SYNC_DUMP_CMD='printf "CUSTOM DUMP LINE\n"' bash "${DIR}/sql-sync/remote-dump.sh"
  assert_success
  assert_output --partial "dump: command"
  run grep -c "CUSTOM DUMP LINE" "${FIXTURE_DIR}/ddev-dumps/sql-sync.sql"
  assert_success
  assert_output "1"
  # mysqldump was never invoked
  [ ! -e "${SQL_SYNC_TEST_CAPTURE}" ]
}

@test "remote dump: drush sql-dump wins when drush is available" {
  set -eu -o pipefail
  STUB_DIR="$(mktemp -d)"
  cat > "${STUB_DIR}/drush" <<'STUBEOF'
#!/usr/bin/env bash
echo "-- drush stub dump"
STUBEOF
  chmod +x "${STUB_DIR}/drush"
  FIXTURE_DIR="$(mktemp -d)"
  mkdir -p "${FIXTURE_DIR}/sites/default"
  echo "<?php // settings fixture" > "${FIXTURE_DIR}/sites/default/settings.php"
  run env PATH="${STUB_DIR}:/usr/bin:/bin" SQL_SYNC_ROOT="${FIXTURE_DIR}" SQL_SYNC_TMP="${FIXTURE_DIR}" SQL_SYNC_PLATFORM=drupal bash "${DIR}/sql-sync/remote-dump.sh"
  assert_success
  assert_output --partial "drush sql-dump"
  run grep -c "drush stub dump" "${FIXTURE_DIR}/ddev-dumps/sql-sync.sql"
  assert_success
  assert_output "1"
}

@test "remote dump: drupal credentials from settings.php fixture" {
  set -eu -o pipefail
  if ! command -v php >/dev/null 2>&1; then
    skip "php is not available in this environment"
  fi
  make_stub_mysqldump
  FIXTURE_DIR="$(mktemp -d)"
  mkdir -p "${FIXTURE_DIR}/sites/default"
  cat > "${FIXTURE_DIR}/sites/default/settings.php" <<'FIXEOF'
<?php
$databases['default']['default'] = [
  'database' => 'drupaldb',
  'username' => 'drupaluser',
  'password' => 'drupalpass',
  'host' => 'localhost',
  'port' => '',
  'driver' => 'mysql',
];
FIXEOF
  export SQL_SYNC_TEST_CAPTURE="${FIXTURE_DIR}/capture.txt"
  run env PATH="${STUB_DIR}:${PATH}" SQL_SYNC_ROOT="${FIXTURE_DIR}" SQL_SYNC_TMP="${FIXTURE_DIR}" SQL_SYNC_PLATFORM=drupal bash "${DIR}/sql-sync/remote-dump.sh"
  assert_success
  assert_output --partial "using mysqldump"
  run cat "${SQL_SYNC_TEST_CAPTURE}"
  assert_output --partial "args: -u drupaluser"
  assert_output --partial "drupaldb"
  assert_output --partial "pw: drupalpass"
}

# Build a minimal fake project layout so the host command can run outside
# DDEV, with ssh, rsync and ddev stubbed on PATH. The stubs record their
# arguments; the rsync stub also fabricates the dump and its completion
# marker (a real transfer would), and the ddev stub answers SHOW TABLES
# from SQL_SYNC_TEST_TABLES and captures the SQL piped into `ddev mysql`.
# Behaviour toggles (all optional): SQL_SYNC_TEST_SSH_FAIL (ssh exits 255),
# SQL_SYNC_TEST_META_PREFIX (the step-1 ssh prints a wp_prefix meta line),
# SQL_SYNC_TEST_GZIP (the fabricated dump is gzipped),
# SQL_SYNC_TEST_NO_MARKER (the marker rsync fails),
# SQL_SYNC_TEST_MARKER_SIZE (the marker carries this size instead),
# SQL_SYNC_TEST_IMPORT_FAIL (ddev import-db exits 1),
# SQL_SYNC_TEST_NO_DRUSH (ddev drush --version exits 1).
make_fake_project() {
  FAKE_DIR="$(mktemp -d)"
  STUB_DIR="$(mktemp -d)"
  mkdir -p "${FAKE_DIR}/.ddev/commands/host" "${FAKE_DIR}/.ddev/sql-sync"
  cp "${DIR}/commands/host/sql-sync" "${FAKE_DIR}/.ddev/commands/host/sql-sync"
  cp "${DIR}/sql-sync/remote-dump.sh" "${DIR}/sql-sync/sanitize-laravel.sql" "${DIR}/sql-sync/sanitize-wordpress.sql" "${FAKE_DIR}/.ddev/sql-sync/"
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
case "$*" in
  import-db*)
    if [ -n "${SQL_SYNC_TEST_IMPORT_FAIL:-}" ]; then
      exit 1
    fi
    ;;
  "drush --version")
    if [ -n "${SQL_SYNC_TEST_NO_DRUSH:-}" ]; then
      exit 1
    fi
    ;;
  mysql*)
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
  export SQL_SYNC_TEST_SSH_CAPTURE="${FAKE_DIR}/ssh-capture.txt"
  export SQL_SYNC_TEST_RSYNC_CAPTURE="${FAKE_DIR}/rsync-capture.txt"
  export SQL_SYNC_TEST_DDEV_CAPTURE="${FAKE_DIR}/ddev-capture.txt"
  export SQL_SYNC_TEST_SANITIZE_CAPTURE="${FAKE_DIR}/sanitize-capture.sql"
}

# A mysql stand-in that answers the information_schema size query with
# SQL_SYNC_TEST_SIZE (bytes). Needs STUB_DIR from make_stub_mysqldump.
make_stub_mysql() {
  cat > "${STUB_DIR}/mysql" <<'STUBEOF'
#!/usr/bin/env bash
echo "${SQL_SYNC_TEST_SIZE:-2048}"
STUBEOF
  chmod +x "${STUB_DIR}/mysql"
}

# A df stand-in that reports a nearly full filesystem (~1 MB available).
make_stub_df() {
  cat > "${STUB_DIR}/df" <<'STUBEOF'
#!/usr/bin/env bash
printf 'Filesystem     1024-blocks    Used Available Capacity Mounted on\n/dev/fake          1000000  999000      1000      99%% /tmp\n'
STUBEOF
  chmod +x "${STUB_DIR}/df"
}

@test "host command: jump host reaches ssh and rsync, absent without jump:" {
  set -eu -o pipefail
  make_fake_project
  cat > "${FAKE_DIR}/.ddev/sql-sync/aliases.yml" <<FIXEOF
local:
  dir: ${FAKE_DIR}/dumps

prod:
  host: app.example.com
  user: deploy
  root: /var/www/example
  jump: bastion.example.com
FIXEOF
  run env HOME="${FAKE_DIR}/home" PATH="${STUB_DIR}:/usr/bin:/bin" bash "${FAKE_DIR}/.ddev/commands/host/sql-sync" @prod @self -y --no-sanitize
  assert_success
  # Both ssh calls (dump + cleanup) carry the -J value
  run grep -c -- "-J bastion.example.com" "${SQL_SYNC_TEST_SSH_CAPTURE}"
  assert_success
  assert_output "2"
  run cat "${SQL_SYNC_TEST_RSYNC_CAPTURE}"
  assert_output --partial "-J bastion.example.com"

  # The same alias without the jump: key: no -J anywhere
  cat > "${FAKE_DIR}/.ddev/sql-sync/aliases.yml" <<FIXEOF
local:
  dir: ${FAKE_DIR}/dumps

prod:
  host: app.example.com
  user: deploy
  root: /var/www/example
FIXEOF
  rm -f "${SQL_SYNC_TEST_SSH_CAPTURE}" "${SQL_SYNC_TEST_RSYNC_CAPTURE}"
  run env HOME="${FAKE_DIR}/home" PATH="${STUB_DIR}:/usr/bin:/bin" bash "${FAKE_DIR}/.ddev/commands/host/sql-sync" @prod @self -y --no-sanitize
  assert_success
  run grep -- "-J" "${SQL_SYNC_TEST_SSH_CAPTURE}"
  assert_failure
  run grep -- "-J" "${SQL_SYNC_TEST_RSYNC_CAPTURE}"
  assert_failure
}

# Invoke remote-dump.sh exactly as commands/host/sql-sync does over ssh:
# the full SQL_SYNC_* environment the ssh command string carries, with the
# script itself fed to bash -s on stdin rather than run as a file. $1 is the
# PATH, $2 the fixture root, $3 the platform (empty: caller passes none).
run_remote_host_form() {
  if [ -n "$3" ]; then
    run env PATH="$1" SQL_SYNC_ROOT="$2" SQL_SYNC_TMP="$2" SQL_SYNC_PLATFORM="$3" SQL_SYNC_DUMP_CMD= SQL_SYNC_DB_NAME= SQL_SYNC_DB_USERNAME= SQL_SYNC_DB_PASSWORD= SQL_SYNC_DB_HOST= SQL_SYNC_DB_PORT= bash -s < "${DIR}/sql-sync/remote-dump.sh"
  else
    run env PATH="$1" SQL_SYNC_ROOT="$2" SQL_SYNC_TMP="$2" SQL_SYNC_DUMP_CMD= SQL_SYNC_DB_NAME= SQL_SYNC_DB_USERNAME= SQL_SYNC_DB_PASSWORD= SQL_SYNC_DB_HOST= SQL_SYNC_DB_PORT= bash -s < "${DIR}/sql-sync/remote-dump.sh"
  fi
}

@test "remote dump (host invocation form): wordpress platform reaches the wp-config extractor" {
  set -eu -o pipefail
  make_stub_mysqldump
  FIXTURE_DIR="$(mktemp -d)"
  cat > "${FIXTURE_DIR}/wp-config.php" <<'FIXEOF'
<?php
define( 'DB_NAME', 'wpdb' );
define( 'DB_USER', 'wpuser' );
define( 'DB_PASSWORD', 'wppass' );
define( 'DB_HOST', 'localhost' );
FIXEOF
  export SQL_SYNC_TEST_CAPTURE="${FIXTURE_DIR}/capture.txt"
  # No wp on this PATH, so the run must land on the mysqldump fallback, and
  # the platform carried in the environment must pick the wp-config
  # extractor (not the .env one).
  run_remote_host_form "${STUB_DIR}:/usr/bin:/bin" "${FIXTURE_DIR}" wordpress
  assert_success
  assert_output --partial "platform: wordpress"
  assert_output --partial "using mysqldump"
  run cat "${SQL_SYNC_TEST_CAPTURE}"
  assert_output --partial "args: -u wpuser"
  assert_output --partial "wpdb"
  assert_output --partial "pw: wppass"
}

@test "remote dump (host invocation form): drupal platform reaches the settings.php extractor" {
  set -eu -o pipefail
  if ! command -v php >/dev/null 2>&1; then
    skip "php is not available in this environment"
  fi
  make_stub_mysqldump
  FIXTURE_DIR="$(mktemp -d)"
  mkdir -p "${FIXTURE_DIR}/sites/default"
  cat > "${FIXTURE_DIR}/sites/default/settings.php" <<'FIXEOF'
<?php
$databases['default']['default'] = [
  'database' => 'drupaldb',
  'username' => 'drupaluser',
  'password' => 'drupalpass',
  'host' => 'localhost',
  'port' => '',
  'driver' => 'mysql',
];
FIXEOF
  export SQL_SYNC_TEST_CAPTURE="${FIXTURE_DIR}/capture.txt"
  # No drush on this PATH (only the stub dir is added), so the run must land
  # on the mysqldump fallback with credentials from settings.php.
  run_remote_host_form "${STUB_DIR}:${PATH}" "${FIXTURE_DIR}" drupal
  assert_success
  assert_output --partial "platform: drupal"
  assert_output --partial "using mysqldump"
  run cat "${SQL_SYNC_TEST_CAPTURE}"
  assert_output --partial "args: -u drupaluser"
  assert_output --partial "drupaldb"
  assert_output --partial "pw: drupalpass"
}

@test "remote dump (host invocation form): no platform prints the php-assumption notice" {
  set -eu -o pipefail
  make_stub_mysqldump
  FIXTURE_DIR="$(mktemp -d)"
  cat > "${FIXTURE_DIR}/.env" <<'FIXEOF'
DB_DATABASE=fixturedb
DB_USERNAME=fixtureuser
DB_PASSWORD=fixturepass
DB_HOST=127.0.0.1
FIXEOF
  export SQL_SYNC_TEST_CAPTURE="${FIXTURE_DIR}/capture.txt"
  # No SQL_SYNC_PLATFORM in the environment at all: the script may assume
  # php, but it must say so — a silent assumption sends wordpress and
  # drupal syncs down the .env extractor with no sign in the output.
  run_remote_host_form "${STUB_DIR}:/usr/bin:/bin" "${FIXTURE_DIR}" ""
  assert_success
  assert_output --partial "no platform specified"
  assert_output --partial "platform: php"
  run cat "${SQL_SYNC_TEST_CAPTURE}"
  assert_output --partial "args: -h 127.0.0.1 -u fixtureuser"
  assert_output --partial "pw: fixturepass"

  # With the platform given explicitly as php, the same .env extraction
  # runs and there is no assumption notice
  run_remote_host_form "${STUB_DIR}:/usr/bin:/bin" "${FIXTURE_DIR}" php
  assert_success
  assert_output --partial "platform: php"
  refute_output --partial "no platform specified"
  run cat "${SQL_SYNC_TEST_CAPTURE}"
  assert_output --partial "args: -h 127.0.0.1 -u fixtureuser"
  assert_output --partial "pw: fixturepass"
}

@test "host command: platform resolution falls back to the DDEV type, then php" {
  set -eu -o pipefail
  make_fake_project
  cat > "${FAKE_DIR}/.ddev/sql-sync/aliases.yml" <<FIXEOF
local:
  dir: ${FAKE_DIR}/dumps

prod:
  host: app.example.com
  user: deploy
  root: /var/www/example
FIXEOF

  # A generic DDEV php project type resolves to the php platform
  printf 'type: php\n' > "${FAKE_DIR}/.ddev/config.yaml"
  run env HOME="${FAKE_DIR}/home" PATH="${STUB_DIR}:/usr/bin:/bin" bash "${FAKE_DIR}/.ddev/commands/host/sql-sync" @prod @self -y --no-sanitize
  assert_success
  run cat "${SQL_SYNC_TEST_SSH_CAPTURE}"
  assert_output --partial "SQL_SYNC_PLATFORM=php"

  # No config.yaml at all also lands on php
  rm -f "${FAKE_DIR}/.ddev/config.yaml" "${SQL_SYNC_TEST_SSH_CAPTURE}"
  run env HOME="${FAKE_DIR}/home" PATH="${STUB_DIR}:/usr/bin:/bin" bash "${FAKE_DIR}/.ddev/commands/host/sql-sync" @prod @self -y --no-sanitize
  assert_success
  run cat "${SQL_SYNC_TEST_SSH_CAPTURE}"
  assert_output --partial "SQL_SYNC_PLATFORM=php"

  # An unrecognised DDEV type lands on php too
  printf 'type: backdrop\n' > "${FAKE_DIR}/.ddev/config.yaml"
  rm -f "${SQL_SYNC_TEST_SSH_CAPTURE}"
  run env HOME="${FAKE_DIR}/home" PATH="${STUB_DIR}:/usr/bin:/bin" bash "${FAKE_DIR}/.ddev/commands/host/sql-sync" @prod @self -y --no-sanitize
  assert_success
  run cat "${SQL_SYNC_TEST_SSH_CAPTURE}"
  assert_output --partial "SQL_SYNC_PLATFORM=php"

  # A recognised type still resolves to itself
  printf 'type: laravel\n' > "${FAKE_DIR}/.ddev/config.yaml"
  rm -f "${SQL_SYNC_TEST_SSH_CAPTURE}"
  run env HOME="${FAKE_DIR}/home" PATH="${STUB_DIR}:/usr/bin:/bin" bash "${FAKE_DIR}/.ddev/commands/host/sql-sync" @prod @self -y --no-sanitize
  assert_success
  run cat "${SQL_SYNC_TEST_SSH_CAPTURE}"
  assert_output --partial "SQL_SYNC_PLATFORM=laravel"
}

@test "remote preflight: wordpress mysqldump fallback reports without dumping or leaking the password" {
  set -eu -o pipefail
  make_stub_mysqldump
  make_stub_mysql
  FIXTURE_DIR="$(mktemp -d)"
  cat > "${FIXTURE_DIR}/wp-config.php" <<'FIXEOF'
<?php
define( 'DB_NAME', 'wpdb' );
define( 'DB_USER', 'wpuser' );
define( 'DB_PASSWORD', 'wppass' );
define( 'DB_HOST', 'localhost' );
FIXEOF
  export SQL_SYNC_TEST_CAPTURE="${FIXTURE_DIR}/capture.txt"
  run env PATH="${STUB_DIR}:/usr/bin:/bin" SQL_SYNC_ROOT="${FIXTURE_DIR}" SQL_SYNC_TMP="${FIXTURE_DIR}" SQL_SYNC_PLATFORM=wordpress SQL_SYNC_PREFLIGHT=1 bash "${DIR}/sql-sync/remote-dump.sh"
  assert_success
  assert_output --partial "platform: wordpress"
  assert_output --partial "preflight: strategy: mysqldump"
  assert_output --partial "preflight: database: wpdb"
  assert_output --partial "preflight: username: wpuser"
  assert_output --partial "preflight: password: resolved (never shown)"
  assert_output --partial "preflight: database size:"
  assert_output --partial "preflight: all checks passed"
  # The fixture password must not appear anywhere in the output
  refute_output --partial "wppass"
  # Nothing was dumped: mysqldump never ran and no dump file exists
  [ ! -e "${SQL_SYNC_TEST_CAPTURE}" ]
  [ ! -e "${FIXTURE_DIR}/sql-sync.sql" ]
  [ ! -e "${FIXTURE_DIR}/ddev-dumps" ]
}

@test "remote dump: aborts before dumping when free space is below the database size" {
  set -eu -o pipefail
  make_stub_mysqldump
  make_stub_mysql
  make_stub_df
  FIXTURE_DIR="$(mktemp -d)"
  cat > "${FIXTURE_DIR}/.env" <<'FIXEOF'
DB_DATABASE=fixturedb
DB_USERNAME=fixtureuser
DB_PASSWORD=fixturepass
DB_HOST=127.0.0.1
FIXEOF
  export SQL_SYNC_TEST_CAPTURE="${FIXTURE_DIR}/capture.txt"
  export SQL_SYNC_TEST_SIZE=100000000000
  run env PATH="${STUB_DIR}:/usr/bin:/bin" SQL_SYNC_ROOT="${FIXTURE_DIR}" SQL_SYNC_TMP="${FIXTURE_DIR}" SQL_SYNC_PLATFORM=laravel bash "${DIR}/sql-sync/remote-dump.sh"
  assert_failure
  assert_output --partial "not enough free space"
  # The abort fired before any dump command ran
  [ ! -e "${SQL_SYNC_TEST_CAPTURE}" ]
  [ ! -e "${FIXTURE_DIR}/sql-sync.sql" ]
  [ ! -e "${FIXTURE_DIR}/ddev-dumps" ]
}

@test "host command: --dry-run runs preflight only, no rsync, no import" {
  set -eu -o pipefail
  make_fake_project
  cat > "${FAKE_DIR}/.ddev/sql-sync/aliases.yml" <<FIXEOF
local:
  dir: ${FAKE_DIR}/dumps

prod:
  host: app.example.com
  user: deploy
  root: /var/www/example
FIXEOF
  run env HOME="${FAKE_DIR}/home" PATH="${STUB_DIR}:/usr/bin:/bin" bash "${FAKE_DIR}/.ddev/commands/host/sql-sync" @prod @self --dry-run
  assert_success
  assert_output --partial "preflight: ok: local dump dir"
  assert_output --partial "preflight: ok: ssh connectivity"
  assert_output --partial "plan: the dump would be downloaded to"
  assert_output --partial "plan: sanitize after import:"
  assert_output --partial "No dump was taken, nothing was imported"
  run cat "${SQL_SYNC_TEST_SSH_CAPTURE}"
  assert_output --partial "SQL_SYNC_PREFLIGHT=1"
  assert_output --partial "BatchMode=yes"
  # No download and no import happened
  [ ! -e "${SQL_SYNC_TEST_RSYNC_CAPTURE}" ]
  [ ! -e "${SQL_SYNC_TEST_DDEV_CAPTURE}" ]
}


@test "remote dump: wp-cli found in HOME/bin when the ssh PATH lacks it" {
  set -eu -o pipefail
  # WP-CLI's commonest install location is ~/bin, which a non-interactive
  # ssh session's PATH does not include; the probe must still find it.
  FIXTURE_DIR="$(mktemp -d)"
  mkdir -p "${FIXTURE_DIR}/home/bin"
  cat > "${FIXTURE_DIR}/home/bin/wp" <<'STUBEOF'
#!/usr/bin/env bash
for last; do :; done
echo "-- wp-cli home-bin dump" > "$last"
STUBEOF
  chmod +x "${FIXTURE_DIR}/home/bin/wp"
  cat > "${FIXTURE_DIR}/wp-config.php" <<'FIXEOF'
<?php
define( 'DB_NAME', 'wpdb' );
FIXEOF
  run env HOME="${FIXTURE_DIR}/home" PATH="/usr/bin:/bin" SQL_SYNC_ROOT="${FIXTURE_DIR}" SQL_SYNC_TMP="${FIXTURE_DIR}" SQL_SYNC_PLATFORM=wordpress bash "${DIR}/sql-sync/remote-dump.sh"
  assert_success
  assert_output --partial "wp db export"
  run grep -c "wp-cli home-bin dump" "${FIXTURE_DIR}/ddev-dumps/sql-sync.sql"
  assert_success
  assert_output "1"
}

@test "remote dump: staging folder is private and a completion marker carries the size" {
  set -eu -o pipefail
  make_stub_mysqldump
  FIXTURE_DIR="$(mktemp -d)"
  cat > "${FIXTURE_DIR}/.env" <<'FIXEOF'
DB_DATABASE=fixturedb
DB_USERNAME=fixtureuser
DB_PASSWORD=fixturepass
DB_HOST=127.0.0.1
FIXEOF
  export SQL_SYNC_TEST_CAPTURE="${FIXTURE_DIR}/capture.txt"
  run env PATH="${STUB_DIR}:/usr/bin:/bin" SQL_SYNC_ROOT="${FIXTURE_DIR}" SQL_SYNC_TMP="${FIXTURE_DIR}" SQL_SYNC_PLATFORM=laravel bash "${DIR}/sql-sync/remote-dump.sh"
  assert_success
  run stat -c %a "${FIXTURE_DIR}/ddev-dumps"
  assert_output "700"
  run stat -c %a "${FIXTURE_DIR}/ddev-dumps/sql-sync.sql"
  assert_output "600"
  run cat "${FIXTURE_DIR}/ddev-dumps/sql-sync.done"
  assert_output "$(wc -c < "${FIXTURE_DIR}/ddev-dumps/sql-sync.sql" | tr -d ' ')"
}

@test "remote dump: a failed dump removes its partial file and leaves no marker" {
  set -eu -o pipefail
  make_stub_mysqldump
  FIXTURE_DIR="$(mktemp -d)"
  cat > "${FIXTURE_DIR}/.env" <<'FIXEOF'
DB_DATABASE=fixturedb
DB_USERNAME=fixtureuser
DB_PASSWORD=fixturepass
DB_HOST=127.0.0.1
FIXEOF
  export SQL_SYNC_TEST_CAPTURE="${FIXTURE_DIR}/capture.txt"
  run env PATH="${STUB_DIR}:/usr/bin:/bin" SQL_SYNC_TEST_DUMP_FAIL=1 SQL_SYNC_ROOT="${FIXTURE_DIR}" SQL_SYNC_TMP="${FIXTURE_DIR}" SQL_SYNC_PLATFORM=laravel bash "${DIR}/sql-sync/remote-dump.sh"
  assert_failure
  [ ! -e "${FIXTURE_DIR}/ddev-dumps/sql-sync.sql" ]
  [ ! -e "${FIXTURE_DIR}/ddev-dumps/sql-sync.done" ]
}

@test "remote dump: wordpress table prefix is reported on a meta line" {
  set -eu -o pipefail
  make_stub_mysqldump
  FIXTURE_DIR="$(mktemp -d)"
  cat > "${FIXTURE_DIR}/wp-config.php" <<'FIXEOF'
<?php
define( 'DB_NAME', 'wpdb' );
define( 'DB_USER', 'wpuser' );
define( 'DB_PASSWORD', 'wppass' );
define( 'DB_HOST', 'localhost' );
$table_prefix = 'blog_';
FIXEOF
  export SQL_SYNC_TEST_CAPTURE="${FIXTURE_DIR}/capture.txt"
  run env PATH="${STUB_DIR}:/usr/bin:/bin" SQL_SYNC_ROOT="${FIXTURE_DIR}" SQL_SYNC_TMP="${FIXTURE_DIR}" SQL_SYNC_PLATFORM=wordpress bash "${DIR}/sql-sync/remote-dump.sh"
  assert_success
  assert_output --partial "sql-sync-meta: wp_prefix=blog_"
}

@test "remote dump: .env export prefixes, inline comments and quoted values" {
  set -eu -o pipefail
  make_stub_mysqldump
  FIXTURE_DIR="$(mktemp -d)"
  cat > "${FIXTURE_DIR}/.env" <<'FIXEOF'
export DB_DATABASE=exportdb # the main database
export DB_USERNAME=exportuser
export DB_PASSWORD="pa#ss word"
export DB_HOST=127.0.0.1 # loopback
FIXEOF
  export SQL_SYNC_TEST_CAPTURE="${FIXTURE_DIR}/capture.txt"
  run env PATH="${STUB_DIR}:/usr/bin:/bin" SQL_SYNC_ROOT="${FIXTURE_DIR}" SQL_SYNC_TMP="${FIXTURE_DIR}" SQL_SYNC_PLATFORM=laravel bash "${DIR}/sql-sync/remote-dump.sh"
  assert_success
  run cat "${SQL_SYNC_TEST_CAPTURE}"
  assert_output --partial "args: -h 127.0.0.1 -u exportuser"
  assert_output --partial "exportdb"
  assert_output --partial "pw: pa#ss word"

  # A single-quoted value keeps its # and spaces too
  cat > "${FIXTURE_DIR}/.env" <<'FIXEOF'
DB_DATABASE=sqdb
DB_USERNAME=squser
DB_PASSWORD='sing # le'
DB_HOST=127.0.0.1
FIXEOF
  run env PATH="${STUB_DIR}:/usr/bin:/bin" SQL_SYNC_ROOT="${FIXTURE_DIR}" SQL_SYNC_TMP="${FIXTURE_DIR}" SQL_SYNC_PLATFORM=laravel bash "${DIR}/sql-sync/remote-dump.sh"
  assert_success
  run cat "${SQL_SYNC_TEST_CAPTURE}"
  assert_output --partial "pw: sing # le"
}

@test "remote dump: dump strategy says when the disk-space check is skipped" {
  set -eu -o pipefail
  FIXTURE_DIR="$(mktemp -d)"
  # No app config and no mysql client on this PATH: the size cannot be
  # estimated, and a normal run must say so instead of staying silent.
  run env PATH="/usr/bin:/bin" SQL_SYNC_ROOT="${FIXTURE_DIR}" SQL_SYNC_TMP="${FIXTURE_DIR}" SQL_SYNC_PLATFORM=php SQL_SYNC_DUMP_CMD='printf "X DUMP\n"' bash "${DIR}/sql-sync/remote-dump.sh"
  assert_success
  assert_output --partial "the disk-space check is skipped for this run"
  run grep -c "X DUMP" "${FIXTURE_DIR}/ddev-dumps/sql-sync.sql"
  assert_success
  assert_output "1"
}

@test "remote dump: dump strategy still guards when credentials resolve" {
  set -eu -o pipefail
  make_stub_mysqldump
  make_stub_mysql
  make_stub_df
  FIXTURE_DIR="$(mktemp -d)"
  cat > "${FIXTURE_DIR}/.env" <<'FIXEOF'
DB_DATABASE=fixturedb
DB_USERNAME=fixtureuser
DB_PASSWORD=fixturepass
DB_HOST=127.0.0.1
FIXEOF
  export SQL_SYNC_TEST_SIZE=100000000000
  run env PATH="${STUB_DIR}:/usr/bin:/bin" SQL_SYNC_ROOT="${FIXTURE_DIR}" SQL_SYNC_TMP="${FIXTURE_DIR}" SQL_SYNC_PLATFORM=laravel SQL_SYNC_DUMP_CMD='printf "X\n"' bash "${DIR}/sql-sync/remote-dump.sh"
  assert_failure
  assert_output --partial "not enough free space"
  [ ! -e "${FIXTURE_DIR}/ddev-dumps" ]
}

@test "host command: the README example block parses clean and dumps land in the real home folder" {
  set -eu -o pipefail
  make_fake_project
  mkdir -p "${FAKE_DIR}/home"
  # The README's example block, verbatim — inline comments and all.
  cat > "${FAKE_DIR}/.ddev/sql-sync/aliases.yml" <<'FIXEOF'
local:
  dir: ~/sql-sync        # where downloaded dumps are kept

prod:
  host: myserver  # an ~/.ssh/config alias or a hostname
  user: deploy           # optional; ssh target becomes user@host
  root: /var/www/example  # the app's path on the server
  tmp: /tmp              # optional; temp folder on the server
FIXEOF
  run env HOME="${FAKE_DIR}/home" PATH="${STUB_DIR}:/usr/bin:/bin" bash "${FAKE_DIR}/.ddev/commands/host/sql-sync" @prod @self -y --no-sanitize
  assert_success
  assert_output --partial "dump file: ${FAKE_DIR}/home/sql-sync/prod.sql"
  run cat "${SQL_SYNC_TEST_SSH_CAPTURE}"
  assert_output --partial "deploy@myserver"
  assert_output --partial "SQL_SYNC_ROOT=/var/www/example"
  [ -d "${FAKE_DIR}/home/sql-sync" ]
  [ ! -e "${FAKE_DIR}/home/~" ]
}

@test "host command: the shipped example file works verbatim" {
  set -eu -o pipefail
  make_fake_project
  mkdir -p "${FAKE_DIR}/home"
  cp "${DIR}/sql-sync/aliases.example.yml" "${FAKE_DIR}/.ddev/sql-sync/aliases.yml"
  run env HOME="${FAKE_DIR}/home" PATH="${STUB_DIR}:/usr/bin:/bin" bash "${FAKE_DIR}/.ddev/commands/host/sql-sync" @prod @self -y --no-sanitize
  assert_success
  assert_output --partial "dump file: ${FAKE_DIR}/home/sql-sync/prod.sql"
  run cat "${SQL_SYNC_TEST_SSH_CAPTURE}"
  assert_output --partial "deploy@myserver"
  [ ! -e "${FAKE_DIR}/home/~" ]
}

@test "host command: inline comments on every key, and the full remote environment in both ssh calls" {
  set -eu -o pipefail
  make_fake_project
  cat > "${FAKE_DIR}/.ddev/sql-sync/aliases.yml" <<'FIXEOF'
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
FIXEOF
  run env HOME="${FAKE_DIR}/home" SQL_SYNC_TEST_TABLES="users" PATH="${STUB_DIR}:/usr/bin:/bin" bash "${FAKE_DIR}/.ddev/commands/host/sql-sync" @prod @self -y
  assert_success
  # Every SQL_SYNC_* key reaches the remote in the real ssh invocation,
  # with the commented values parsed clean.
  run cat "${SQL_SYNC_TEST_SSH_CAPTURE}"
  assert_output --partial "deploy@myserver"
  assert_output --partial "SQL_SYNC_ROOT=/var/www/example"
  assert_output --partial "SQL_SYNC_TMP=/tmp"
  assert_output --partial "SQL_SYNC_PLATFORM=laravel"
  assert_output --partial "SQL_SYNC_DB_NAME=appdb"
  assert_output --partial "SQL_SYNC_DB_USERNAME=appuser"
  assert_output --partial "SQL_SYNC_DB_PASSWORD=pa#ss"
  assert_output --partial "SQL_SYNC_DB_HOST=db.internal"
  assert_output --partial "SQL_SYNC_DB_PORT=3307"
  assert_output --partial "-J bastion.example.com"

  # The preflight ssh call carries the same environment, plus PREFLIGHT.
  rm -f "${SQL_SYNC_TEST_SSH_CAPTURE}"
  run env HOME="${FAKE_DIR}/home" PATH="${STUB_DIR}:/usr/bin:/bin" bash "${FAKE_DIR}/.ddev/commands/host/sql-sync" @prod @self --dry-run
  assert_success
  run cat "${SQL_SYNC_TEST_SSH_CAPTURE}"
  assert_output --partial "SQL_SYNC_ROOT=/var/www/example"
  assert_output --partial "SQL_SYNC_PLATFORM=laravel"
  assert_output --partial "SQL_SYNC_DB_PASSWORD=pa#ss"
  assert_output --partial "SQL_SYNC_DB_PORT=3307"
  assert_output --partial "SQL_SYNC_PREFLIGHT=1"
}

@test "host command: a duplicate alias definition is a hard error" {
  set -eu -o pipefail
  make_fake_project
  cat > "${FAKE_DIR}/.ddev/sql-sync/aliases.yml" <<'FIXEOF'
prod:
  host: first.example.com
  user: deploy
  root: /var/www/first

prod:
  host: second.example.com
  user: deploy
  root: /var/www/second
FIXEOF
  run env HOME="${FAKE_DIR}/home" PATH="${STUB_DIR}:/usr/bin:/bin" bash "${FAKE_DIR}/.ddev/commands/host/sql-sync" @prod @self -y --no-sanitize
  assert_failure
  assert_output --partial "defined more than once"
  [ ! -e "${SQL_SYNC_TEST_SSH_CAPTURE}" ]
}

@test "host command: a failed dump ssh stops the run before any rsync" {
  set -eu -o pipefail
  make_fake_project
  cat > "${FAKE_DIR}/.ddev/sql-sync/aliases.yml" <<'FIXEOF'
prod:
  host: app.example.com
  user: deploy
  root: /var/www/example
FIXEOF
  run env HOME="${FAKE_DIR}/home" SQL_SYNC_TEST_SSH_FAIL=1 PATH="${STUB_DIR}:/usr/bin:/bin" bash "${FAKE_DIR}/.ddev/commands/host/sql-sync" @prod @self -y --no-sanitize
  assert_failure
  assert_output --partial "the dump step failed"
  [ ! -e "${SQL_SYNC_TEST_RSYNC_CAPTURE}" ]
}

@test "host command: --no-sync only creates the server-side dump" {
  set -eu -o pipefail
  make_fake_project
  cat > "${FAKE_DIR}/.ddev/sql-sync/aliases.yml" <<'FIXEOF'
prod:
  host: app.example.com
  user: deploy
  root: /var/www/example
FIXEOF
  run env HOME="${FAKE_DIR}/home" PATH="${STUB_DIR}:/usr/bin:/bin" bash "${FAKE_DIR}/.ddev/commands/host/sql-sync" @prod @self --no-sync
  assert_success
  assert_output --partial "nothing downloaded or imported"
  [ ! -e "${SQL_SYNC_TEST_RSYNC_CAPTURE}" ]
  [ ! -e "${SQL_SYNC_TEST_DDEV_CAPTURE}" ]
}

@test "host command: --no-dump requires the completion marker and a matching size" {
  set -eu -o pipefail
  make_fake_project
  cat > "${FAKE_DIR}/.ddev/sql-sync/aliases.yml" <<'FIXEOF'
prod:
  host: app.example.com
  user: deploy
  root: /var/www/example
FIXEOF
  # Marker cannot be downloaded: refuse before importing anything
  run env HOME="${FAKE_DIR}/home" SQL_SYNC_TEST_NO_MARKER=1 SQL_SYNC_TEST_TABLES="users" PATH="${STUB_DIR}:/usr/bin:/bin" bash "${FAKE_DIR}/.ddev/commands/host/sql-sync" @prod @self -y --no-dump --no-sanitize
  assert_failure
  assert_output --partial "completion marker"
  [ ! -e "${SQL_SYNC_TEST_DDEV_CAPTURE}" ]

  # Marker size disagrees with the downloaded dump: refuse
  run env HOME="${FAKE_DIR}/home" SQL_SYNC_TEST_MARKER_SIZE=999999 SQL_SYNC_TEST_TABLES="users" PATH="${STUB_DIR}:/usr/bin:/bin" bash "${FAKE_DIR}/.ddev/commands/host/sql-sync" @prod @self -y --no-dump --no-sanitize
  assert_failure
  assert_output --partial "refusing to import"
  [ ! -e "${SQL_SYNC_TEST_DDEV_CAPTURE}" ]

  # Marker present and matching: the earlier dump imports
  run env HOME="${FAKE_DIR}/home" SQL_SYNC_TEST_TABLES="users" PATH="${STUB_DIR}:/usr/bin:/bin" bash "${FAKE_DIR}/.ddev/commands/host/sql-sync" @prod @self -y --no-dump --no-sanitize
  assert_success
  run cat "${SQL_SYNC_TEST_DDEV_CAPTURE}"
  assert_output --partial "import-db"
}

@test "host command: a gzipped dump is imported as .sql.gz" {
  set -eu -o pipefail
  make_fake_project
  cat > "${FAKE_DIR}/.ddev/sql-sync/aliases.yml" <<'FIXEOF'
prod:
  host: app.example.com
  user: deploy
  root: /var/www/example
FIXEOF
  run env HOME="${FAKE_DIR}/home" SQL_SYNC_TEST_GZIP=1 PATH="${STUB_DIR}:/usr/bin:/bin" bash "${FAKE_DIR}/.ddev/commands/host/sql-sync" @prod @self -y --no-sanitize
  assert_success
  assert_output --partial "the dump is gzipped"
  run cat "${SQL_SYNC_TEST_DDEV_CAPTURE}"
  assert_output --partial "import-db --file="
  assert_output --partial "prod.sql.gz"
  [ -f "${FAKE_DIR}/home/sql-sync/prod.sql.gz" ]
}

@test "host command: a failed import keeps the remote dump and skips cleanup" {
  set -eu -o pipefail
  make_fake_project
  cat > "${FAKE_DIR}/.ddev/sql-sync/aliases.yml" <<'FIXEOF'
prod:
  host: app.example.com
  user: deploy
  root: /var/www/example
FIXEOF
  run env HOME="${FAKE_DIR}/home" SQL_SYNC_TEST_IMPORT_FAIL=1 PATH="${STUB_DIR}:/usr/bin:/bin" bash "${FAKE_DIR}/.ddev/commands/host/sql-sync" @prod @self -y --no-sanitize
  assert_failure
  assert_output --partial "kept on the server"
  run grep "rm -f" "${SQL_SYNC_TEST_SSH_CAPTURE}"
  assert_failure
}

@test "host command: sanitize selection for laravel and wordpress" {
  set -eu -o pipefail
  make_fake_project

  # Laravel with a users table: bundled SQL runs
  cat > "${FAKE_DIR}/.ddev/sql-sync/aliases.yml" <<'FIXEOF'
prod:
  host: app.example.com
  user: deploy
  root: /var/www/example
  platform: laravel
FIXEOF
  run env HOME="${FAKE_DIR}/home" SQL_SYNC_TEST_TABLES="users" PATH="${STUB_DIR}:/usr/bin:/bin" bash "${FAKE_DIR}/.ddev/commands/host/sql-sync" @prod @self -y
  assert_success
  run cat "${SQL_SYNC_TEST_SANITIZE_CAPTURE}"
  assert_output --partial "UPDATE \`users\`"

  # Laravel without a users table: the run fails WITHOUT sanitize
  rm -f "${SQL_SYNC_TEST_SANITIZE_CAPTURE}"
  run env HOME="${FAKE_DIR}/home" SQL_SYNC_TEST_TABLES="posts" PATH="${STUB_DIR}:/usr/bin:/bin" bash "${FAKE_DIR}/.ddev/commands/host/sql-sync" @prod @self -y
  assert_failure
  assert_output --partial "completed WITHOUT sanitize"

  # WordPress with the prefix reported by the server: prefixed table runs
  cat > "${FAKE_DIR}/.ddev/sql-sync/aliases.yml" <<'FIXEOF'
prod:
  host: app.example.com
  user: deploy
  root: /var/www/example
  platform: wordpress
FIXEOF
  rm -f "${SQL_SYNC_TEST_SANITIZE_CAPTURE}"
  run env HOME="${FAKE_DIR}/home" SQL_SYNC_TEST_META_PREFIX="site_" SQL_SYNC_TEST_TABLES="site_users site_options" PATH="${STUB_DIR}:/usr/bin:/bin" bash "${FAKE_DIR}/.ddev/commands/host/sql-sync" @prod @self -y
  assert_success
  run cat "${SQL_SYNC_TEST_SANITIZE_CAPTURE}"
  assert_output --partial "UPDATE \`site_users\`"

  # WordPress on a --no-dump run: the prefix is detected from the tables
  rm -f "${SQL_SYNC_TEST_SANITIZE_CAPTURE}"
  run env HOME="${FAKE_DIR}/home" SQL_SYNC_TEST_TABLES="blog_users blog_options" PATH="${STUB_DIR}:/usr/bin:/bin" bash "${FAKE_DIR}/.ddev/commands/host/sql-sync" @prod @self -y --no-dump
  assert_success
  run cat "${SQL_SYNC_TEST_SANITIZE_CAPTURE}"
  assert_output --partial "UPDATE \`blog_users\`"

  # WordPress with no users table at all: failure, not a quiet skip
  rm -f "${SQL_SYNC_TEST_SANITIZE_CAPTURE}"
  run env HOME="${FAKE_DIR}/home" SQL_SYNC_TEST_TABLES="wp_posts wp_options" PATH="${STUB_DIR}:/usr/bin:/bin" bash "${FAKE_DIR}/.ddev/commands/host/sql-sync" @prod @self -y
  assert_failure
  assert_output --partial "completed WITHOUT sanitize"
}

@test "host command: sanitize selection for drupal, an alias file, and php" {
  set -eu -o pipefail
  make_fake_project

  # Drupal with Drush: sql-sanitize runs
  cat > "${FAKE_DIR}/.ddev/sql-sync/aliases.yml" <<'FIXEOF'
prod:
  host: app.example.com
  user: deploy
  root: /var/www/example
  platform: drupal
FIXEOF
  run env HOME="${FAKE_DIR}/home" PATH="${STUB_DIR}:/usr/bin:/bin" bash "${FAKE_DIR}/.ddev/commands/host/sql-sync" @prod @self -y
  assert_success
  run cat "${SQL_SYNC_TEST_DDEV_CAPTURE}"
  assert_output --partial "drush sql-sanitize"

  # Drupal with a sanitize: file: the file wins over Drush
  printf -- '-- custom sanitize\nUPDATE users SET email = "x";\n' > "${FAKE_DIR}/my-sanitize.sql"
  cat > "${FAKE_DIR}/.ddev/sql-sync/aliases.yml" <<'FIXEOF'
prod:
  host: app.example.com
  user: deploy
  root: /var/www/example
  platform: drupal
  sanitize: my-sanitize.sql
FIXEOF
  rm -f "${SQL_SYNC_TEST_DDEV_CAPTURE}" "${SQL_SYNC_TEST_SANITIZE_CAPTURE}"
  run env HOME="${FAKE_DIR}/home" PATH="${STUB_DIR}:/usr/bin:/bin" bash "${FAKE_DIR}/.ddev/commands/host/sql-sync" @prod @self -y
  assert_success
  run cat "${SQL_SYNC_TEST_SANITIZE_CAPTURE}"
  assert_output --partial "UPDATE users SET email"
  run grep "drush sql-sanitize" "${SQL_SYNC_TEST_DDEV_CAPTURE}"
  assert_failure

  # Drupal without Drush and without a file: failure WITHOUT sanitize
  cat > "${FAKE_DIR}/.ddev/sql-sync/aliases.yml" <<'FIXEOF'
prod:
  host: app.example.com
  user: deploy
  root: /var/www/example
  platform: drupal
FIXEOF
  run env HOME="${FAKE_DIR}/home" SQL_SYNC_TEST_NO_DRUSH=1 PATH="${STUB_DIR}:/usr/bin:/bin" bash "${FAKE_DIR}/.ddev/commands/host/sql-sync" @prod @self -y
  assert_failure
  assert_output --partial "completed WITHOUT sanitize"

  # A sanitize: file also wins over the bundled laravel SQL
  cat > "${FAKE_DIR}/.ddev/sql-sync/aliases.yml" <<'FIXEOF'
prod:
  host: app.example.com
  user: deploy
  root: /var/www/example
  platform: laravel
  sanitize: my-sanitize.sql
FIXEOF
  rm -f "${SQL_SYNC_TEST_SANITIZE_CAPTURE}"
  run env HOME="${FAKE_DIR}/home" SQL_SYNC_TEST_TABLES="users" PATH="${STUB_DIR}:/usr/bin:/bin" bash "${FAKE_DIR}/.ddev/commands/host/sql-sync" @prod @self -y
  assert_success
  run cat "${SQL_SYNC_TEST_SANITIZE_CAPTURE}"
  assert_output --partial "-- custom sanitize"

  # Generic php: no sanitize exists, so the default run fails loudly
  cat > "${FAKE_DIR}/.ddev/sql-sync/aliases.yml" <<'FIXEOF'
prod:
  host: app.example.com
  user: deploy
  root: /var/www/example
FIXEOF
  run env HOME="${FAKE_DIR}/home" PATH="${STUB_DIR}:/usr/bin:/bin" bash "${FAKE_DIR}/.ddev/commands/host/sql-sync" @prod @self -y
  assert_failure
  assert_output --partial "completed WITHOUT sanitize"
}


# bats test_tags=release
@test "install from release" {
  set -eu -o pipefail
  echo "# ddev add-on get ${GITHUB_REPO} with project ${PROJNAME} in $(pwd)" >&3

  run ddev add-on get "${GITHUB_REPO}"
  assert_success

  assert_file_exist .ddev/commands/host/sql-sync
  assert_file_exist .ddev/sql-sync/remote-dump.sh
  assert_file_exist .ddev/sql-sync/aliases.yml

  run ddev sql-sync --help
  assert_success
}
