# Shared setup for claude.sh / stop.sh. Sourced, not executed.
#   project_env <project-dir>  -> exports PROJECT_DIR, AUTH_DIR, REPO_DIR, UID, GID,
#                                 SERVICE, VOLUME_NAME, COMPOSE_* and cds to the repo root.
project_env() {
  PROJECT_DIR=$(realpath "$1")
  [ -d "$PROJECT_DIR" ] || { echo "not a directory: $PROJECT_DIR" >&2; return 1; }
  cd "$(dirname "${BASH_SOURCE[0]}")/.."
  REPO_DIR=$PWD
  mkdir -p .claude/auth && chmod 700 .claude/auth
  AUTH_DIR=$(realpath .claude/auth)

  # One compose stack (claude-container) for all projects; each project is its own
  # service and container, named after the folder. The state volume keeps a hash of the
  # *full* path so two projects with the same basename don't share history/permissions.
  local hash slug
  hash=$(printf '%s' "$PROJECT_DIR" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-8)
  slug=$(basename "$PROJECT_DIR" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9_\n' '-' | sed 's/^[^a-z0-9]*//')
  SERVICE=${slug:-project}
  VOLUME_NAME="claude-$SERVICE-${hash}_config"
  GID=$(id -g)
  export PROJECT_DIR AUTH_DIR REPO_DIR UID GID SERVICE VOLUME_NAME
  export COMPOSE_PROJECT_NAME=claude-container
  export COMPOSE_IGNORE_ORPHANS=true   # the other projects' containers are not orphans

  # Mount .git read-only, but only when it is a real directory. Docker creates a missing
  # bind-mount source as an empty directory, which would plant a bogus .git in a project
  # that isn't a repo; and when .git is a *file* (submodule, or a worktree checkout) the
  # real git dir lives elsewhere on the host and is not mounted, so git can't work anyway.
  local files=compose.yaml
  if [ -d "$PROJECT_DIR/.git" ]; then
    files="$files compose.git.yaml"
  elif [ -f "$PROJECT_DIR/.git" ]; then
    echo "note: $PROJECT_DIR/.git is a file (submodule or linked worktree);" \
         "its git dir is outside the project, so git will not work in the container" >&2
  fi

  # Compose can't interpolate a service key, so render the templates (service `claude`)
  # with this project's service name into a scratch dir and point COMPOSE_FILE there.
  local gen f out; gen="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/claude-container"
  mkdir -p "$gen"; COMPOSE_FILE=""
  for f in $files; do
    out="$gen/$SERVICE-$hash.$f"
    sed "s/^  claude:\$/  $SERVICE:/" "$f" > "$out"
    COMPOSE_FILE="$COMPOSE_FILE${COMPOSE_FILE:+:}$out"
  done
  export COMPOSE_FILE
}
