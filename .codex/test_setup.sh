#!/usr/bin/env bash
#
# Prepares the Redmine checkout created by redmine_clone.sh: picks a Ruby the
# checkout accepts, installs the gems and migrates the test database.
#
#   ./.codex/test_setup.sh
#
# Environment:
#   REDMINE_DIR            checkout to prepare (default: redmine)
#   CMA_DB                 postgresql (default), mysql or mariadb
#   CMA_DB_NAME/_USER/_PASSWORD/_HOST/_PORT
#                          connection details, defaults suit a local install
#   CMA_PROVISION_DB       1 to install and start the server locally (needs sudo),
#                          0 to assume it is already reachable. Defaults to 0 in
#                          CI, 1 otherwise.
#   CMA_RUBY               pin the Ruby version instead of deriving it
#   MISE_BIN               mise executable, used only when it is present
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Test defaults, not secrets: they exist so a fresh checkout runs without
# configuration. Never point these at anything that holds real data.
CMA_DB="${CMA_DB:-postgresql}"
CMA_DB_NAME="${CMA_DB_NAME:-redmine_test}"
CMA_DB_USER="${CMA_DB_USER:-redmine}"
CMA_DB_PASSWORD="${CMA_DB_PASSWORD:-redmine}"
CMA_DB_HOST="${CMA_DB_HOST:-127.0.0.1}"

# The engine asked for and the Active Record adapter are two different things, and
# collapsing them was a real trap: MySQL and MariaDB share the mysql2 adapter but
# not their optimisers, and this script used to install Ubuntu's
# default-mysql-server for both, which is MariaDB. Asking for MySQL and silently
# getting MariaDB hid a query that never returns on MySQL through ten local runs.
case "$CMA_DB" in
  postgresql|postgres|pg) CMA_ENGINE=postgresql; CMA_ADAPTER=postgresql; CMA_DB_PORT="${CMA_DB_PORT:-5432}" ;;
  mysql|mysql2)           CMA_ENGINE=mysql;      CMA_ADAPTER=mysql2;     CMA_DB_PORT="${CMA_DB_PORT:-3306}" ;;
  mariadb)                CMA_ENGINE=mariadb;    CMA_ADAPTER=mysql2;     CMA_DB_PORT="${CMA_DB_PORT:-3306}" ;;
  *) echo "ERROR: CMA_DB must be postgresql, mysql or mariadb, got '$CMA_DB'." >&2; exit 1 ;;
esac

if [ -z "${CMA_PROVISION_DB:-}" ]; then
  if [ "${CI:-}" = "true" ]; then CMA_PROVISION_DB=0; else CMA_PROVISION_DB=1; fi
fi

[ -d "$REDMINE_DIR" ] || {
  echo "ERROR: '$REDMINE_DIR' not found. Run ./.codex/redmine_clone.sh first." >&2
  exit 1
}

# --- Ruby -------------------------------------------------------------------
cma_select_ruby install

# --- Database server --------------------------------------------------------
if [ "$CMA_PROVISION_DB" = 1 ]; then
  echo "Provisioning a local $CMA_ENGINE server (set CMA_PROVISION_DB=0 to skip)."
  sudo apt-get update
  if [ "$CMA_ENGINE" = postgresql ]; then
    sudo apt-get install -y build-essential libpq-dev postgresql postgresql-contrib
    sudo service postgresql start
    # CREATEDB is all the suite needs; no superuser, and a name of its own so an
    # existing development role is never touched.
    sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$CMA_DB_USER'" | grep -q 1 ||
      sudo -u postgres psql -c "CREATE ROLE $CMA_DB_USER WITH LOGIN CREATEDB PASSWORD '$CMA_DB_PASSWORD';"
    sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$CMA_DB_NAME'" | grep -q 1 ||
      sudo -u postgres createdb -O "$CMA_DB_USER" "$CMA_DB_NAME"
  else
    # Named packages, not default-mysql-server: on Ubuntu that is MariaDB.
    if [ "$CMA_ENGINE" = mysql ]; then
      sudo apt-get install -y build-essential default-libmysqlclient-dev mysql-server
    else
      sudo apt-get install -y build-essential default-libmysqlclient-dev mariadb-server
    fi
    sudo service mariadb start 2>/dev/null || sudo service mysql start
    sudo mysql -e "CREATE DATABASE IF NOT EXISTS \`$CMA_DB_NAME\` CHARACTER SET utf8mb4;"
    sudo mysql -e "CREATE USER IF NOT EXISTS '$CMA_DB_USER'@'$CMA_DB_HOST' IDENTIFIED BY '$CMA_DB_PASSWORD';"
    sudo mysql -e "GRANT ALL ON \`$CMA_DB_NAME\`.* TO '$CMA_DB_USER'@'$CMA_DB_HOST'; FLUSH PRIVILEGES;"
    # browser_test.sh runs on a database of its own.
    sudo mysql -e "GRANT ALL ON \`${CMA_BROWSER_DB_NAME:-${CMA_DB_NAME}_browser}\`.* TO '$CMA_DB_USER'@'$CMA_DB_HOST'; FLUSH PRIVILEGES;"
  fi
fi

# --- Configuration ----------------------------------------------------------
cat > "$REDMINE_DIR/config/database.yml" <<EOF
test:
  adapter: $CMA_ADAPTER
  database: $CMA_DB_NAME
  host: $CMA_DB_HOST
  port: $CMA_DB_PORT
  username: $CMA_DB_USER
  password: "$CMA_DB_PASSWORD"
  encoding: $([ "$CMA_ENGINE" = postgresql ] && echo unicode || echo utf8mb4)
EOF

# Exported rather than written as a `RAILS_ENV=test run ...` prefix: bash keeps
# such an assignment in effect after a *function* call, which is a surprise
# waiting to happen.
export RAILS_ENV=test

(cd "$REDMINE_DIR" && bundle config set --local without 'development')
(cd "$REDMINE_DIR" && bundle config set --local path 'vendor/bundle')

run bundle install

# Redmine ships no schema.rb, but a previous run may have dumped one for another
# adapter, which db:migrate would then try to load.
rm -f "$REDMINE_DIR/db/schema.rb"

run bundle exec rake db:create db:migrate
run bundle exec rake redmine:plugins:migrate
rm -f "$REDMINE_DIR/db/schema.rb"

# Say which server actually answered. MySQL and MariaDB are interchangeable to the
# adapter and not to this plugin, so the log has to make the difference visible.
reported="$(run bundle exec rails runner \
  'print ActiveRecord::Base.connection.select_value("SELECT VERSION()")' 2>/dev/null || true)"
echo "Server reports: ${reported:-unknown}"

case "$CMA_ENGINE:$reported" in
  mysql:*MariaDB*|mysql:*mariadb*)
    echo "WARNING: CMA_DB=mysql but the server is MariaDB. They do not behave the same" >&2
    echo "         here; install mysql-server, or use CMA_DB=mariadb and mean it." >&2
    ;;
  mariadb:*)
    case "$reported" in
      *MariaDB*|*mariadb*) ;;
      *) echo "WARNING: CMA_DB=mariadb but the server does not report MariaDB." >&2 ;;
    esac
    ;;
esac

echo "Ready. Run ./.codex/test_plugin.sh"
