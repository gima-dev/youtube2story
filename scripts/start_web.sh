#!/usr/bin/env bash
set -euo pipefail

# Wrapper to start web.rb under project Bundler environment for launchd
ROOT_DIR="/Users/gima/ruby_projects/youtube2story"
cd "$ROOT_DIR"

# Export bundler env to ensure correct gemset
export BUNDLE_GEMFILE="$ROOT_DIR/Gemfile"
export GEM_HOME="$ROOT_DIR/vendor/bundle"
export GEM_PATH="$GEM_HOME"
export PATH="$ROOT_DIR/vendor/bundle/ruby/3.2.0/bin:$PATH"

# Log files (launchd will also capture stdout/stderr if configured)
STDOUT_LOG="/tmp/y2s_web.log"
STDERR_LOG="/tmp/y2s_web.err"

mkdir -p "$(dirname "$STDOUT_LOG")"
touch "$STDOUT_LOG" "$STDERR_LOG"
chown $(whoami):admin "$STDOUT_LOG" "$STDERR_LOG" || true

# Exec so pid stays as script process for launchd
exec env BUNDLE_GEMFILE="$BUNDLE_GEMFILE" GEM_HOME="$GEM_HOME" GEM_PATH="$GEM_PATH" \
  PATH="$PATH" $(which ruby) -rbundler/setup web.rb >>"$STDOUT_LOG" 2>>"$STDERR_LOG"
