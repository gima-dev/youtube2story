#!/usr/bin/env bash
set -euo pipefail

# Wrapper to start web.rb under project Bundler environment for launchd
ROOT_DIR="/Users/gima/ruby_projects/youtube2story"
cd "$ROOT_DIR"

# Prefer Homebrew Ruby; fall back to PATH ruby
RUBY_BIN="/usr/local/opt/ruby/bin/ruby"
if [ ! -x "$RUBY_BIN" ]; then
  RUBY_BIN="$(which ruby || true)"
  if [ -z "$RUBY_BIN" ]; then
    echo "ruby not found in /usr/local/opt/ruby or PATH" >&2
    exit 1
  fi
fi

# Determine ruby version for vendor path
RUBY_VERSION="$($RUBY_BIN -e 'print RUBY_VERSION')"

# Export bundler env to ensure correct gemset (project-local vendor/bundle)
export BUNDLE_GEMFILE="$ROOT_DIR/Gemfile"
export GEM_HOME="$ROOT_DIR/vendor/bundle"
export GEM_PATH="$GEM_HOME"
# Ensure common bin dirs and project vendor bin are in PATH
export PATH="/usr/local/opt/ruby/bin:/usr/local/bin:/usr/bin:/bin:$ROOT_DIR/vendor/bundle/ruby/$RUBY_VERSION/bin:$PATH"

# Log files (launchd will also capture stdout/stderr if configured)
STDOUT_LOG="$HOME/Library/Logs/y2s_web.log"
STDERR_LOG="$HOME/Library/Logs/y2s_web.err"

mkdir -p "$(dirname "$STDOUT_LOG")"
touch "$STDOUT_LOG" "$STDERR_LOG"

# Exec so pid stays as script process for launchd; use explicit Ruby binary
exec env BUNDLE_GEMFILE="$BUNDLE_GEMFILE" GEM_HOME="$GEM_HOME" GEM_PATH="$GEM_PATH" \
  PATH="$PATH" "$RUBY_BIN" -rbundler/setup web.rb >>"$STDOUT_LOG" 2>>"$STDERR_LOG"
