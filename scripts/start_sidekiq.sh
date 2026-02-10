#!/usr/bin/env bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT" || exit 1
mkdir -p log

# Export bundler/Gem env to prefer vendor/bundle
export BUNDLE_GEMFILE="$PROJECT_ROOT/Gemfile"
export GEM_HOME="$PROJECT_ROOT/vendor/bundle"
export GEM_PATH="$GEM_HOME"

# Ensure brew paths first, then vendor bins
export PATH="/opt/homebrew/bin:/usr/local/bin:$PROJECT_ROOT/vendor/bundle/bin:$PATH"
for d in "$GEM_HOME"/ruby/*/bin; do
	if [ -d "$d" ]; then
		PATH="$d:$PATH"
	fi
done
export PATH

# Prefer vendor binstub for Sidekiq if it exists and is executable
# Prefer project shim if present
SHIM="$PROJECT_ROOT/scripts/sidekiq_shim"
if [ -x "$SHIM" ]; then
	exec "$SHIM"
fi

# Prefer vendor binstub for Sidekiq if it exists and is executable
SIDECMD="$(echo "$GEM_HOME"/ruby/*/bin/sidekiq | awk '{print $1}')"
if [ -x "$SIDECMD" ]; then
	exec "$SIDECMD" -r "$PROJECT_ROOT"/workers/process_worker.rb >> "$PROJECT_ROOT"/log/sidekiq.log 2>> "$PROJECT_ROOT"/log/sidekiq.err.log
fi

# Fallback: use ruby with bundler/setup to activate project gems
exec ruby -rbundler/setup -S sidekiq -r "$PROJECT_ROOT"/workers/process_worker.rb >> "$PROJECT_ROOT"/log/sidekiq.log 2>> "$PROJECT_ROOT"/log/sidekiq.err.log
