# claude-container

Run Claude Code in a throwaway Arch Linux container, one container per project.
Claude sees exactly one folder on the host (the project) and nothing else.

## Usage

```bash
scripts/claude.sh /path/to/project            # build (first time), start, open claude
scripts/claude.sh /path/to/project --resume   # extra args go straight to claude
scripts/stop.sh   /path/to/project            # stop the container
scripts/stop.sh   /path/to/project --purge    # stop and forget this project's state
```

First run: `claude` prints a login URL. Open it on the host, paste the code back.
Later projects skip the wizard: `claude.sh` marks onboarding done in the new volume
whenever a shared login already exists (Claude Code would otherwise ask you to log in
again, even though the token is valid). The per-project trust dialog still appears.

## Login sharing

`.claude/auth/` on the host is bind-mounted into every container at
`~/.claude-auth`, and `~/.claude/.credentials.json` inside the container is a
symlink into it. All containers therefore read and write **one** credential file:
when Claude Code rotates the OAuth token in one project, every other project sees
the new token immediately, instead of being left with a refresh token the server
has already invalidated. (Claude Code may replace the symlink with a real file
when it writes; `claude.sh` folds that file back into the shared mount and
restores the link after every run.)

Only the login and `settings.json` are shared. `.claude.json` is **not**: it holds
the account identity, MCP server configs, and a per-project entry — keyed by the
path *inside* the container, which is `/workspace` for every project — carrying
that project's approved tool permissions, trust-dialog state and prompt history.
Sharing it would silently pre-approve one project's permissions in all the others.
It stays in each project's own Docker volume, along with session history.

To log out everywhere: `rm .claude/auth/.credentials.json`. `--purge` does not
remove it; it only deletes that project's state volume.

`.claude/auth/` is gitignored and mode 700, but the OAuth access **and refresh**
tokens sit there in plaintext — the native install would normally keep them in the
OS keyring. Treat that directory as a credential: don't copy the repo with it, and
keep it out of backups and file sync.

## Git: readable, not writable

Git is installed, and the repository's `.git` is bind-mounted **read-only** over the project
mount. Reads work normally — `log`, `diff`, `show`, `blame`, `status`, `grep` — so diffs and
`/code-review` are available. Every write fails.

Three separate things are doing the work, and they are not equally strong:

| Control | Stops | Strength |
|---|---|---|
| `.git` mounted `:ro` (`compose.git.yaml`) | commits, index writes, ref updates, fetch, `worktree add`, and any config/hook written into the repo | Real. Container root cannot remount it rw; that needs `CAP_SYS_ADMIN`, which Docker drops. |
| No credentials anywhere in the container | `push`, and authenticated `fetch`/`ls-remote` | Real, and this is what actually blocks push — see below. |
| `/usr/local/bin/git` wrapper (`scripts/git-ro`) | mutating subcommands, plus `-c`, `-C`, `--git-dir`, `--exec-path` | **Not a boundary.** It only makes blocked commands explain themselves. `/usr/bin/git` is still there, and `sudo pacman` is container root. |

Push deserves the explicit note: `git push` updates the *remote* before it writes the local
remote-tracking ref, so a read-only `.git` would not reliably stop a push that had
credentials. It has none — no SSH key, no token, no credential helper, no `~/.gitconfig`
auth, and `GIT_TERMINAL_PROMPT=0` so git fails instead of prompting. If you want push
blocked at the kernel level too, that means an egress allowlist in a sidecar network
namespace (`network_mode: service:firewall`), because container root can flush iptables in
its own namespace.

Consequences worth knowing:

- **`claude --worktree` does not work**, and neither do subagents with `isolation: worktree`:
  `git worktree add` writes to `.git`. Run those sessions on the host.
- Checkpoints and `/rewind` are unaffected — Claude Code stores those as file snapshots in
  `~/.claude/projects/`, not as git commits.
- `~/.cache/git/index` is a writable copy of the index, refreshed at container start, so
  `status`/`diff` keep their stat cache. A commit made on the host mid-session makes the
  copy stale and `status` will show spurious changes until the next `scripts/claude.sh` run.
- The mount is only added when `$PROJECT_DIR/.git` is a real directory. If the project isn't
  a repo it is skipped (Docker would otherwise create an empty `.git` on the host); if `.git`
  is a *file* — a submodule or linked worktree — the real git dir is outside the project and
  the script warns that git won't work there.

## What's in the container

- `archlinux:base`, `pacman` with [Chaotic-AUR](https://aur.chaotic.cx/) enabled: AUR packages
  install as prebuilt binaries with `sudo pacman -S <pkg>`. That is the only sudo command
  allowed — though note `pacman -U <url>` runs install hooks as root, so it is in practice
  a root shell in the container, and container root can rewrite files in the bind-mounted
  project. The container is the boundary, the `claude` user is not.
- Claude Code native binary, runs as non-root user `claude` with the host's UID/GID,
  so files it writes belong to you.
- Git, read-only (above). Internet access, no other host mounts, no docker socket.

Not included: yay/paru (they need makepkg and a writable git; Chaotic-AUR covers most AUR
packages).

## How to access Claude in the container

Confirmed against the Claude Code docs (Sep 2026):

| Method | Status |
|---|---|
| CLI | Works. `scripts/claude.sh` runs `docker compose exec claude claude`. |
| Web UI on an exposed port | Not supported. Claude Code has no built-in web server. |
| Web / mobile via Remote Control | Works. Run `scripts/claude.sh <project> remote-control`, then open the session on claude.ai/code or the mobile app. Outbound tunnel, no port to expose. Team/Enterprise plans need an admin to enable it. |
| Claude Desktop | Only via SSH connections. Would need an sshd in the container, not built. |

## Layout

- `Dockerfile` — the image.
- `compose.yaml` — template: mounts `$PROJECT_DIR` at `/workspace`, a named volume at
  `~/.claude` (per project) and `$AUTH_DIR` at `~/.claude-auth` (shared).
- `scripts/lib.sh` — sets those variables and renders the templates. All projects live in
  **one** compose stack, `claude-container`; each project is its own service and container,
  named after its folder (`uls-rs`). Compose can't interpolate a service key, so `lib.sh`
  copies the templates with the `claude` key replaced into `$XDG_RUNTIME_DIR/claude-container/`
  and points `COMPOSE_FILE` there. The state volume is `claude-<folder>-<hash of the full
  path>_config`: the hash keeps two projects with the same folder name from sharing history
  and permissions (their containers would still clash on the name — rename one).
- `compose.git.yaml` — the read-only `.git` mount, rendered and added to `COMPOSE_FILE` by
  `lib.sh` only when the project is a git repo.
- `scripts/git-ro` — the read-only git wrapper, installed in the image as
  `/usr/local/bin/git`.
- `docs/git-readonly.md` — the design note for the read-only git setup.

## License

MIT — see [LICENSE](LICENSE).
