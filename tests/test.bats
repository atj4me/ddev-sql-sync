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
  run grep -c "wp-cli stub dump" "${FIXTURE_DIR}/sql-sync.sql"
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
  run grep -c "CUSTOM DUMP LINE" "${FIXTURE_DIR}/sql-sync.sql"
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
  run grep -c "drush stub dump" "${FIXTURE_DIR}/sql-sync.sql"
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
# DDEV, with ssh, rsync and ddev stubbed on PATH recording their arguments.
make_fake_project() {
  FAKE_DIR="$(mktemp -d)"
  STUB_DIR="$(mktemp -d)"
  mkdir -p "${FAKE_DIR}/.ddev/commands/host" "${FAKE_DIR}/.ddev/sql-sync"
  cp "${DIR}/commands/host/sql-sync" "${FAKE_DIR}/.ddev/commands/host/sql-sync"
  cp "${DIR}/sql-sync/remote-dump.sh" "${DIR}/sql-sync/sanitize-laravel.sql" "${DIR}/sql-sync/sanitize-wordpress.sql" "${FAKE_DIR}/.ddev/sql-sync/"
  cat > "${STUB_DIR}/ssh" <<'STUBEOF'
#!/usr/bin/env bash
printf 'ssh: %s\n' "$*" >> "${SQL_SYNC_TEST_SSH_CAPTURE}"
exit 0
STUBEOF
  cat > "${STUB_DIR}/rsync" <<'STUBEOF'
#!/usr/bin/env bash
printf 'rsync: %s\n' "$*" >> "${SQL_SYNC_TEST_RSYNC_CAPTURE}"
exit 0
STUBEOF
  cat > "${STUB_DIR}/ddev" <<'STUBEOF'
#!/usr/bin/env bash
printf 'ddev: %s\n' "$*" >> "${SQL_SYNC_TEST_DDEV_CAPTURE}"
exit 0
STUBEOF
  chmod +x "${STUB_DIR}/ssh" "${STUB_DIR}/rsync" "${STUB_DIR}/ddev"
  export SQL_SYNC_TEST_SSH_CAPTURE="${FAKE_DIR}/ssh-capture.txt"
  export SQL_SYNC_TEST_RSYNC_CAPTURE="${FAKE_DIR}/rsync-capture.txt"
  export SQL_SYNC_TEST_DDEV_CAPTURE="${FAKE_DIR}/ddev-capture.txt"
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
  run env PATH="${STUB_DIR}:/usr/bin:/bin" bash "${FAKE_DIR}/.ddev/commands/host/sql-sync" @prod @self -y --no-sanitize
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
  run env PATH="${STUB_DIR}:/usr/bin:/bin" bash "${FAKE_DIR}/.ddev/commands/host/sql-sync" @prod @self -y --no-sanitize
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
  run env PATH="${STUB_DIR}:/usr/bin:/bin" bash "${FAKE_DIR}/.ddev/commands/host/sql-sync" @prod @self -y --no-sanitize
  assert_success
  run cat "${SQL_SYNC_TEST_SSH_CAPTURE}"
  assert_output --partial "SQL_SYNC_PLATFORM=php"

  # No config.yaml at all also lands on php
  rm -f "${FAKE_DIR}/.ddev/config.yaml" "${SQL_SYNC_TEST_SSH_CAPTURE}"
  run env PATH="${STUB_DIR}:/usr/bin:/bin" bash "${FAKE_DIR}/.ddev/commands/host/sql-sync" @prod @self -y --no-sanitize
  assert_success
  run cat "${SQL_SYNC_TEST_SSH_CAPTURE}"
  assert_output --partial "SQL_SYNC_PLATFORM=php"

  # An unrecognised DDEV type lands on php too
  printf 'type: backdrop\n' > "${FAKE_DIR}/.ddev/config.yaml"
  rm -f "${SQL_SYNC_TEST_SSH_CAPTURE}"
  run env PATH="${STUB_DIR}:/usr/bin:/bin" bash "${FAKE_DIR}/.ddev/commands/host/sql-sync" @prod @self -y --no-sanitize
  assert_success
  run cat "${SQL_SYNC_TEST_SSH_CAPTURE}"
  assert_output --partial "SQL_SYNC_PLATFORM=php"

  # A recognised type still resolves to itself
  printf 'type: laravel\n' > "${FAKE_DIR}/.ddev/config.yaml"
  rm -f "${SQL_SYNC_TEST_SSH_CAPTURE}"
  run env PATH="${STUB_DIR}:/usr/bin:/bin" bash "${FAKE_DIR}/.ddev/commands/host/sql-sync" @prod @self -y --no-sanitize
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
  run env PATH="${STUB_DIR}:/usr/bin:/bin" bash "${FAKE_DIR}/.ddev/commands/host/sql-sync" @prod @self --dry-run
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
