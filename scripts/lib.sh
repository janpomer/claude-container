# Shared setup for claude.sh / stop.sh. Sourced, not executed.
#   project_env <project-dir>  -> exports PROJECT_DIR, AUTH_DIR, UID, GID,
#                                 COMPOSE_PROJECT_NAME, COMPOSE_FILE
#                                 and cds to the repo root.
project_env() {
  PROJECT_DIR=$(realpath "$1")
  [ -d "$PROJECT_DIR" ] || { echo "not a directory: $PROJECT_DIR" >&2; return 1; }
  cd "$(dirname "${BASH_SOURCE[0]}")/.."
  mkdir -p .claude/auth && chmod 700 .claude/auth
  AUTH_DIR=$(realpath .claude/auth)

  # Container identity: readable slug + hash of the *full* path, so two projects
  # that happen to share a basename don't end up sharing a container and volume.
  local hash slug
  hash=$(printf '%s' "$PROJECT_DIR" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-8)
  slug=$(basename "$PROJECT_DIR" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9_\n' '-' | sed 's/^[^a-z0-9]*//')
  export PROJECT_DIR AUTH_DIR UID GID
  GID=$(id -g)
  export COMPOSE_PROJECT_NAME="claude-${slug:-project}-$hash"

  # Mount .git read-only, but only when it is a real directory. Docker creates a missing
  # bind-mount source as an empty directory, which would plant a bogus .git in a project
  # that isn't a repo; and when .git is a *file* (submodule, or a worktree checkout) the
  # real git dir lives elsewhere on the host and is not mounted, so git can't work anyway.
  export COMPOSE_FILE=compose.yaml
  if [ -d "$PROJECT_DIR/.git" ]; then
    COMPOSE_FILE=compose.yaml:compose.git.yaml
  elif [ -f "$PROJECT_DIR/.git" ]; then
    echo "note: $PROJECT_DIR/.git is a file (submodule or linked worktree);" \
         "its git dir is outside the project, so git will not work in the container" >&2
  fi
}
