#!/usr/bin/env bash
#
# Runs the browser specs (spec/browser/*.test.js) with headless Chromium against
# a Redmine test server, on a database of their own: core fixtures plus the seed
# in spec/browser/seed.rb. The rspec suite keeps its own database untouched.
#
#   ./.codex/browser_test.sh                 # all browser specs
#   ./.codex/browser_test.sh notes           # spec/browser/notes.test.js only
#   CMA_SCREENSHOTS=docs/screenshots/6.1 ./.codex/browser_test.sh screenshots
#
# Why not Redmine's own system tests: they drive Chrome through chromedriver,
# which has to match the browser version exactly. Playwright drives its own
# Chromium, the one this project's CI and sandboxes provide.
#
# Environment (besides the CMA_DB* ones test_setup.sh documents):
#   CMA_BROWSER_PORT     port of the test server (default 3333)
#   CMA_BROWSER_DB_NAME  database of the server (default <CMA_DB_NAME>_browser)
#   CMA_BROWSER_KEEP     1 to leave the server running afterwards
#   PLAYWRIGHT_MODULE    path to the playwright package (default: resolved by node)
#   CMA_SCREENSHOTS      directory the screenshot spec writes to
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

CMA_DB="${CMA_DB:-postgresql}"
CMA_DB_NAME="${CMA_DB_NAME:-redmine_test}"
CMA_DB_USER="${CMA_DB_USER:-redmine}"
CMA_DB_PASSWORD="${CMA_DB_PASSWORD:-redmine}"
CMA_DB_HOST="${CMA_DB_HOST:-127.0.0.1}"
CMA_BROWSER_PORT="${CMA_BROWSER_PORT:-3333}"
CMA_BROWSER_DB_NAME="${CMA_BROWSER_DB_NAME:-${CMA_DB_NAME}_browser}"

# The URL is merged into database.yml, so it names every key that differs per
# engine; the encoding of a MySQL database.yml must not leak into PostgreSQL.
case "$CMA_DB" in
  postgresql|postgres|pg) url="postgresql://$CMA_DB_USER:$CMA_DB_PASSWORD@$CMA_DB_HOST:${CMA_DB_PORT:-5432}/$CMA_BROWSER_DB_NAME?encoding=unicode" ;;
  mysql|mysql2|mariadb)   url="mysql2://$CMA_DB_USER:$CMA_DB_PASSWORD@$CMA_DB_HOST:${CMA_DB_PORT:-3306}/$CMA_BROWSER_DB_NAME?encoding=utf8mb4" ;;
  *) echo "ERROR: unknown CMA_DB '$CMA_DB'." >&2; exit 1 ;;
esac

[ -d "$REDMINE_DIR/plugins/$PLUGIN_NAME" ] || {
  echo "ERROR: plugin not installed in '$REDMINE_DIR'. Run ./.codex/redmine_clone.sh first." >&2
  exit 1
}

cma_select_ruby quiet

# The screenshot of the settings page shows the warning about
# redmine_issue_todo_lists2 before 2.3.0. A stub stands in for that plugin, in
# this checkout and for this run only, and only when no real one is installed.
stub="$REDMINE_DIR/plugins/redmine_issue_todo_lists2"
stub_created=0
if [ -n "${CMA_SCREENSHOTS:-}" ] && [ ! -e "$stub" ]; then
  mkdir -p "$stub"
  cat > "$stub/init.rb" <<'STUB'
# Stub written by .codex/browser_test.sh for the screenshots. Not a plugin.
Redmine::Plugin.register :redmine_issue_todo_lists2 do
  name 'Issue To-do Lists Plugin (stub)'
  version '2.2.2'
  settings :default => {'enable_dates_context_menu' => true}
end
STUB
  stub_created=1
fi
# Redmine's test environment switches CSRF protection off. The browser server
# turns it back on, so every form and remote request carries a real token, as
# in production. The initializer only acts in a process started with
# CMA_BROWSER_CSRF=1: an rspec run on the same checkout is not affected.
csrf_init="$REDMINE_DIR/config/initializers/zz_cma_browser_csrf.rb"
cat > "$csrf_init" <<'RUBY'
# Written by redmine_context_menu_actions/.codex/browser_test.sh, removed on exit.
if ENV['CMA_BROWSER_CSRF'] == '1'
  ActiveSupport.on_load(:action_controller_base) { self.allow_forgery_protection = true }
end
RUBY
remove_stub() {
  if [ "$stub_created" = 1 ]; then rm -rf "$stub"; fi
  rm -f "$csrf_init"
}
trap remove_stub EXIT

export RAILS_ENV=test
# Overrides the database of the test environment for this script only.
export DATABASE_URL="$url"

# A server left over from an earlier run would hold the database open.
pidfile="$REDMINE_DIR/tmp/pids/cma-browser.pid"
stop_server() {
  if [ -f "$pidfile" ]; then
    kill "$(cat "$pidfile")" 2>/dev/null || true
    for _ in $(seq 20); do [ -f "$pidfile" ] || break; sleep 0.5; done
    rm -f "$pidfile"
  fi
}
stop_server

run bundle exec rake db:drop db:create db:migrate redmine:plugins:migrate >/dev/null
run bundle exec rake db:fixtures:load >/dev/null
run bundle exec rails runner "plugins/$PLUGIN_NAME/spec/browser/seed.rb"

log="$REDMINE_DIR/log/browser-server.log"
CMA_BROWSER_CSRF=1 run bundle exec rails server -e test -b 127.0.0.1 -p "$CMA_BROWSER_PORT" -P "tmp/pids/cma-browser.pid" >"$log" 2>&1 &
server=$!
cleanup() {
  if [ "${CMA_BROWSER_KEEP:-0}" != 1 ]; then
    stop_server
    kill "$server" 2>/dev/null || true
  fi
  remove_stub
}
trap cleanup EXIT

for _ in $(seq 120); do
  if curl -fsS -o /dev/null "http://127.0.0.1:$CMA_BROWSER_PORT/login"; then break; fi
  sleep 1
done
curl -fsS -o /dev/null "http://127.0.0.1:$CMA_BROWSER_PORT/login" || {
  echo "ERROR: the test server did not start; see $log" >&2
  exit 1
}

targets=()
if [ "$#" -eq 0 ]; then
  targets=("$PLUGIN_ROOT"/spec/browser/*.test.js)
else
  for name in "$@"; do targets+=("$PLUGIN_ROOT/spec/browser/$name.test.js"); done
fi

if [ -n "${CMA_SCREENSHOTS:-}" ]; then
  mkdir -p "$CMA_SCREENSHOTS"
  CMA_SCREENSHOTS="$(cd "$CMA_SCREENSHOTS" && pwd)"
  export CMA_SCREENSHOTS
fi

CMA_BASE_URL="http://127.0.0.1:$CMA_BROWSER_PORT" \
CMA_REDMINE_VERSION="$(cd "$REDMINE_DIR" && sed -n "s/^ *MAJOR *= *\([0-9]*\).*/\1/p; s/^ *MINOR *= *\([0-9]*\).*/\1/p" lib/redmine/version.rb | head -2 | paste -sd.)" \
  node --test --test-concurrency=1 "${targets[@]}"
