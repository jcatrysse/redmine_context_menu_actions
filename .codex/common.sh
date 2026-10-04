#!/usr/bin/env bash
#
# Shared helpers for the .codex scripts. Sourced, not executed.
#
# Environment:
#   REDMINE_DIR     checkout to work in (default: redmine)
#   MISE_BIN        mise executable, used only when it is present
#   RBENV_BIN       rbenv executable, used when mise is absent and rbenv is present
#   CMA_RUBY        pin the Ruby version instead of deriving it from the Gemfile
#   CMA_RUBY_MAX    newest Ruby that actually exists (default: 3.4)

REDMINE_DIR="${REDMINE_DIR:-redmine}"
MISE_BIN="${MISE_BIN:-mise}"
RBENV_BIN="${RBENV_BIN:-rbenv}"
CMA_RUBY_MAX="${CMA_RUBY_MAX:-3.4}"

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Used by the scripts that source this file, not here.
# shellcheck disable=SC2034
PLUGIN_NAME="$(basename "$PLUGIN_ROOT")"

# Compares two "major.minor" strings. Returns 0 when $1 <= $2.
cma_version_le() {
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n | head -n 1)" = "$1" ]
}

# Prints the lower bound of the checkout's Ruby constraint, "major.minor".
cma_ruby_lower_bound() {
  local gemfile="$REDMINE_DIR/Gemfile" line
  [ -f "$gemfile" ] || return 0
  line="$(grep -E "^[[:space:]]*ruby[[:space:]]" "$gemfile" | head -n 1 || true)"
  # The quote sits before the operator: ruby '>= 3.2.0', '< 3.5.0'.
  printf '%s' "$line" | sed -E -n "s/.*>=[[:space:]]*([0-9]+\.[0-9]+).*/\1/p"
}

# Redmine pins a range rather than a version, so derive one just below the upper
# bound: "< 3.5.0" means 3.4 is the newest Ruby the checkout accepts. Redmine 7
# allows "< 4.1.0", which would derive a Ruby 4.0 that does not exist yet, so the
# result is clamped to CMA_RUBY_MAX and floored at the lower bound.
cma_detect_ruby_version() {
  local gemfile="$REDMINE_DIR/Gemfile" line lower upper major minor candidate

  if [ -n "${CMA_RUBY:-}" ]; then
    echo "$CMA_RUBY"
    return 0
  fi

  [ -f "$gemfile" ] || return 0

  line="$(grep -E "^[[:space:]]*ruby[[:space:]]" "$gemfile" | head -n 1 || true)"
  [ -n "$line" ] || return 0

  lower="$(cma_ruby_lower_bound)"
  upper="$(printf '%s' "$line" | sed -E -n "s/.*<[[:space:]]*['\"]?([0-9]+)\.([0-9]+).*/\1.\2/p")"

  if [ -n "$upper" ]; then
    major="${upper%%.*}"
    minor="${upper##*.}"
    [ "$minor" -gt 0 ] && minor=$((minor - 1))
    candidate="${major}.${minor}"
  else
    candidate="$lower"
  fi

  [ -n "$candidate" ] || return 0

  # Never ask for a Ruby that has not been released.
  cma_version_le "$candidate" "$CMA_RUBY_MAX" || candidate="$CMA_RUBY_MAX"
  # ...and never fall below what the checkout requires.
  if [ -n "$lower" ] && ! cma_version_le "$lower" "$candidate"; then
    candidate="$lower"
  fi

  echo "$candidate"
}

# Picks the newest Ruby rbenv has installed that the checkout accepts: at most
# RUBY_TARGET, at least the Gemfile's lower bound. rbenv cannot install on demand
# the way mise can, so the best fit among what is there is the useful answer.
cma_rbenv_pick() {
  local target="$1" lower version best=""
  lower="$(cma_ruby_lower_bound)"
  while read -r version; do
    version="${version#\* }"
    version="${version%% *}"
    case "$version" in [0-9]*.[0-9]*.[0-9]*) ;; *) continue ;; esac
    cma_version_le "${version%.*}" "$target" || continue
    if [ -n "$lower" ] && ! cma_version_le "$lower" "${version%.*}"; then
      continue
    fi
    best="$version"
  done < <("$RBENV_BIN" versions --bare 2>/dev/null | sort -t. -k1,1n -k2,2n -k3,3n)
  echo "$best"
}

# Sets RUBY_TARGET, USE_MISE and USE_RBENV. Pass "install" to let mise fetch the
# Ruby, anything else to select a Ruby that is expected to be there already.
cma_select_ruby() {
  local mode="${1:-}"

  RUBY_TARGET="$(cma_detect_ruby_version)"
  USE_MISE=0
  USE_RBENV=0
  RBENV_TARGET=""

  if [ -n "$RUBY_TARGET" ] && command -v "$MISE_BIN" >/dev/null 2>&1; then
    if [ "$mode" = install ]; then
      # Local, not global: a project script has no business repointing the machine.
      "$MISE_BIN" install "ruby@$RUBY_TARGET"
      echo "Using Ruby $RUBY_TARGET through mise."
    fi
    USE_MISE=1
  elif [ -n "$RUBY_TARGET" ] && command -v "$RBENV_BIN" >/dev/null 2>&1; then
    RBENV_TARGET="$(cma_rbenv_pick "$RUBY_TARGET")"
    if [ -n "$RBENV_TARGET" ]; then
      USE_RBENV=1
      if [ "$mode" = install ]; then
        echo "Using Ruby $RBENV_TARGET through rbenv (checkout accepts up to $RUBY_TARGET)."
      fi
    fi
  fi

  if [ "$USE_MISE" = 0 ] && [ "$USE_RBENV" = 0 ] && [ -n "$RUBY_TARGET" ] && [ "$mode" = install ]; then
    echo "mise and rbenv not usable; using the Ruby already on PATH ($(ruby -e 'print RUBY_VERSION' 2>/dev/null || echo 'none'))."
    echo "This checkout expects Ruby ~$RUBY_TARGET; bundler will complain if it does not fit."
  fi

  # Never let the function's status be the status of the last test it happened to
  # run: under `set -e` in the caller a stray 1 here kills the script silently.
  return 0
}

# Runs a command inside the Redmine checkout, through mise or rbenv when in use.
run() {
  if [ "${USE_MISE:-0}" = 1 ]; then
    (cd "$REDMINE_DIR" && "$MISE_BIN" exec "ruby@$RUBY_TARGET" -- "$@")
  elif [ "${USE_RBENV:-0}" = 1 ]; then
    (cd "$REDMINE_DIR" && RBENV_VERSION="$RBENV_TARGET" "$RBENV_BIN" exec "$@")
  else
    (cd "$REDMINE_DIR" && "$@")
  fi
}
