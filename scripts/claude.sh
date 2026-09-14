#!/usr/bin/env bash
# Start (and build if needed) the container for a project, then open claude in it.
#   scripts/claude.sh /path/to/project [claude args...]
#
# The login is shared across projects by *mounting* it, not by copying it:
# .claude/auth is bind-mounted into every container and ~/.claude/.credentials.json
# is a symlink into that mount, so an OAuth refresh in one container is immediately
# visible to all the others instead of leaving them with a stale refresh token.
# Everything else in ~/.claude (.claude.json, history, todos, per-project tool
# permissions) stays in the project's own volume and is never shared.
set -euo pipefail
[ $# -ge 1 ] || { echo "usage: $0 <project-dir> [claude args...]"; exit 1; }
source "$(dirname "$0")/lib.sh"
project_env "$1"; shift

docker compose up -d --build --quiet-pull

CFG=/home/claude/.claude
SHARED=/home/claude/.claude-auth

# Adopt any credential a previous login left inside the container, then link
# ~/.claude/.credentials.json into the shared mount. settings.json is seeded once.
docker compose exec -T -e CFG="$CFG" -e SHARED="$SHARED" "$SERVICE" sh -e -c '
  if [ -f "$CFG/.credentials.json" ] && [ ! -L "$CFG/.credentials.json" ]; then
    [ -f "$SHARED/.credentials.json" ] || cp "$CFG/.credentials.json" "$SHARED/.credentials.json"
    rm -f "$CFG/.credentials.json"
  fi
  ln -sfn "$SHARED/.credentials.json" "$CFG/.credentials.json"
  if [ ! -f "$CFG/settings.json" ] && [ -f "$SHARED/settings.json" ]; then
    cp "$SHARED/settings.json" "$CFG/settings.json"
  fi

  # The first-run wizard asks for a login even when a valid credential is present
  # (claude auth status says logged in, but the wizard ignores stored tokens). Once a
  # shared login exists, mark onboarding done so a new project goes straight to the
  # trust dialog. Only the flag is seeded; everything else stays per-project.
  if [ -f "$SHARED/.credentials.json" ] && ! grep -q hasCompletedOnboarding "$CFG/.claude.json" 2>/dev/null; then
    if [ -f "$CFG/.claude.json" ]; then sed -i "1s/^{\$/{\"hasCompletedOnboarding\":true,/" "$CFG/.claude.json"
    else (umask 077; echo "{\"hasCompletedOnboarding\":true}" > "$CFG/.claude.json"); fi
  fi

  # Writable copy of the index: .git is mounted read-only, so git cannot refresh the
  # stat cache in place. The wrapper points GIT_INDEX_FILE here. Refreshed once per
  # run, so a host-side commit mid-session makes it stale until the next run.
  if [ -f /workspace/.git/index ]; then
    mkdir -p "$HOME/.cache/git" && cp -f /workspace/.git/index "$HOME/.cache/git/index"
  else
    rm -f "$HOME/.cache/git/index"   # project is no longer a repo
  fi
'

docker compose exec "$SERVICE" claude "$@" || true

# claude may write credentials by rename, which replaces the symlink with a real
# file; fold that back into the shared mount so the next run still shares it.
docker compose exec -T -e CFG="$CFG" -e SHARED="$SHARED" "$SERVICE" sh -c '
  if [ -f "$CFG/.credentials.json" ] && [ ! -L "$CFG/.credentials.json" ]; then
    mv -f "$CFG/.credentials.json" "$SHARED/.credentials.json"
    ln -sfn "$SHARED/.credentials.json" "$CFG/.credentials.json"
  fi
  [ -f "$CFG/settings.json" ] && cp -f "$CFG/settings.json" "$SHARED/settings.json"
  true
' || true
