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

  # Unknown alias fails before any ssh attempt
  run ddev sql-sync @nope -y
  assert_failure
  assert_output --partial "unknown alias"

  # Missing aliases.yml fails with instructions
  rm .ddev/sql-sync/aliases.yml
  run ddev sql-sync @prod -y
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
  assert_output --partial "-u fixtureuser"
  assert_output --partial "fixturedb"
  assert_output --partial "-h 127.0.0.1"
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
  assert_output --partial "-u mergeuser"
  assert_output --partial "mergedb"
  assert_output --partial "pw: override-pass"
  assert_output --partial "-h db.internal.example"
  assert_output --partial "-P 3307"
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
  assert_output --partial "-u wpuser"
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
  assert_output --partial "-u drupaluser"
  assert_output --partial "drupaldb"
  assert_output --partial "pw: drupalpass"
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
