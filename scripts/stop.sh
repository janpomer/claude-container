#!/usr/bin/env bash
# Stop a project's container. Add --purge to also delete its state volume
# (session history, per-project tool permissions). The shared login in
# .claude/auth is host-side and is never touched; delete that file to log out.
#   scripts/stop.sh /path/to/project [--purge]
set -euo pipefail
[ $# -ge 1 ] || { echo "usage: $0 <project-dir> [--purge]"; exit 1; }
source "$(dirname "$0")/lib.sh"
project_env "$1"

case "${2:-}" in
  "")       docker compose down ;;
  --purge)  docker compose down -v ;;
  *)        echo "unknown option: $2 (did you mean --purge?)" >&2; exit 1 ;;
esac
