# Read-only git in claude-container

## Context

The container currently ships without git "by design", to keep the agent from pushing or
rewriting history. The cost is high: no diffs, no `git log`, no blame, and `/code-review`
is unusable. We want git's read side back without giving the agent any way to mutate the
repository.

Decisions taken: history is strictly read-only (no local commits), enforcement must be
kernel-level with a wrapper on top for legible errors, and `sudo pacman` stays — which
means **any in-container control is advisory**, because passwordless pacman is effectively
container root. Only two things are real boundaries here:

1. A Docker **read-only bind mount** of `<project>/.git`. Container root cannot remount it
   rw without `CAP_SYS_ADMIN`, which Docker drops by default.
2. The **absence of any credential** in the container (no SSH key, no token, no credential
   helper, no `~/.gitconfig` auth) — this is what actually blocks `push`, not the mount.

That second point matters and should be stated in the README rather than assumed: `git push`
updates the remote *before* it writes the local remote-tracking ref, so a read-only `.git`
would not reliably stop a push that had credentials. It has none.

Verified for this design (via the Claude Code docs): checkpoints/rewind use file snapshots
in `~/.claude/projects/`, not the repo, and `/code-review` and `/security-review` only read
git. The one casualty is `git worktree add`, so `claude --worktree` and subagents with
`isolation: worktree` will not work inside the container.

## Changes

### 1. `Dockerfile` — install git, no credentials, safe defaults

- Add `git` to the existing `pacman -Syu --noconfirm sudo curl` line.
- Add a root-owned `/etc/gitconfig` with `[safe] directory = /workspace` and **no**
  `credential.helper`.
- Add to the existing `ENV` block:
  `GIT_OPTIONAL_LOCKS=0` (stops `git status` trying to refresh/write the index),
  `GIT_TERMINAL_PROMPT=0`, `GIT_ASKPASS=/bin/false`, `SSH_ASKPASS=/bin/false` — so a git
  command that wants credentials fails immediately instead of hanging on a prompt.
- `COPY scripts/git-ro /usr/local/bin/git` (root-owned, `0755`). `/usr/local/bin` precedes
  `/usr/bin` in the default `PATH`, and `/home/claude/.local/bin` is already prepended
  ahead of both — check the built image's `PATH` order and put the wrapper first if needed.

### 2. `scripts/git-ro` (new) — the wrapper

A small `sh` script, deliberately a denylist-free **allowlist**:

- Permitted subcommands: `status log diff show blame annotate grep ls-files ls-tree
  rev-parse rev-list cat-file describe shortlog name-rev merge-base diff-tree diff-index
  whatchanged count-objects check-ignore check-attr version help`, plus list-only forms:
  `branch` / `tag` (only with `-l|--list|-a|-v`), `remote -v`, `stash list`,
  `worktree list`, `config --get|--get-all|--list`.
- Rejected outright, before dispatch, are the global flags that can redirect git or execute
  code: `-c`, `--config-env`, `--exec-path`, `--git-dir`, `--work-tree`, `-C`,
  `--namespace`, `--upload-pack`, `--receive-pack`. `-c core.pager=`, `-c alias.*` and
  `-c core.hooksPath=` are arbitrary command execution, so this is not optional.
- Everything else exits non-zero with: `git is read-only in this container (.git is mounted
  ro). Commit, fetch and push on the host.`
- Exports `GIT_OPTIONAL_LOCKS=0` and `GIT_INDEX_FILE=$HOME/.cache/git/index`, then
  `exec /usr/bin/git "$@"`.

Reuse `scripts/lib.sh` conventions for style, but this file ships **into the image**, so it
must be POSIX `sh` and must not source anything.

### 3. Writable index copy

With `.git` read-only, git cannot refresh the index stat cache; `GIT_OPTIONAL_LOCKS=0`
makes that silent rather than an error, but every `status`/`diff` then re-hashes files.
Fix it by pointing `GIT_INDEX_FILE` at a writable copy:

- In `scripts/claude.sh`, in the existing pre-run `docker compose exec` block (the one that
  sets up the credential symlink), add: if `/workspace/.git/index` exists, `mkdir -p
  ~/.cache/git && cp /workspace/.git/index ~/.cache/git/index`.
- Copy once per run, so a host-side commit mid-session makes it stale — `status` then shows
  spurious changes until the next `claude.sh` run. Note this in the README.
- Bonus: because the copy is outside `.git`, even a direct `/usr/bin/git add` mutates only
  the throwaway copy, and the object write it needs fails on the read-only mount.

### 4. `compose.git.yaml` (new) + `scripts/lib.sh` — the read-only mount

Compose cannot conditionally include a volume, and a project may not be a git repo, so use
a second file selected by `COMPOSE_FILE`:

```yaml
# compose.git.yaml
services:
  claude:
    volumes:
      - ${PROJECT_DIR:?}/.git:/workspace/.git:ro
```

In `project_env` (`scripts/lib.sh`), after `PROJECT_DIR` is resolved:

- If `$PROJECT_DIR/.git` is a **directory** → `export COMPOSE_FILE="compose.yaml:compose.git.yaml"`.
- If it is a **file** (submodule or worktree checkout — the real git dir lives elsewhere on
  the host and is not mounted) → skip the mount and print a one-line warning that git will
  not work for this project.
- If it is **absent** → skip the mount. This guard is required, not cosmetic: Docker creates
  a missing bind-mount source as an empty directory on the host, which would plant a bogus
  `.git` in a non-repo project.

Setting it in `lib.sh` means both `claude.sh` and `stop.sh` stay unchanged in how they call
`docker compose`, and both see the same file set.

### 5. `README.md`

Replace the "no git, by design" claims:

- Git is installed and read-only. State which of the three controls does what: the ro mount
  blocks local mutation, the missing credentials block push/fetch, the wrapper only produces
  readable errors and is bypassable via `/usr/bin/git` or `sudo pacman`.
- `--worktree` and `isolation: worktree` subagents do not work in the container.
- The stale-index caveat from §3.
- Note the option not taken: making push kernel-enforced would need an egress allowlist in a
  sidecar network namespace (`network_mode: service:firewall`), since container root can
  flush iptables in its own namespace.

## Files

- `Dockerfile` — git, `/etc/gitconfig`, env vars, `COPY` the wrapper
- `scripts/git-ro` — new
- `compose.git.yaml` — new
- `scripts/lib.sh` — `.git` detection, `COMPOSE_FILE`
- `scripts/claude.sh` — index copy in the existing pre-run exec block
- `README.md`

## Verification

Run against a real repo (e.g. `/workspace/uls-go`), after `scripts/claude.sh <repo>`:

1. **Reads work** — `git log --oneline -3`, `git status`, `git diff`, `git blame <file>`,
   `git show HEAD` all succeed. `git status` reports the same branch/dirty state as the host.
2. **Mount is hard** — `touch /workspace/.git/x` → `Read-only file system`.
   `/usr/bin/git commit --allow-empty -m x` (bypassing the wrapper) → fails on the ro mount.
   Confirm on the host that `git log` is unchanged and `.git` has no new files.
3. **Wrapper messages** — `git commit`, `git push`, `git fetch`, `git rebase`, `git clean -fdx`
   each exit non-zero with the read-only message; `git -c core.pager=id log` is rejected for
   the `-c` flag, not passed through.
4. **No credentials** — `git ls-remote origin` fails without prompting (proves
   `GIT_TERMINAL_PROMPT=0` and that no helper is configured).
5. **Non-repo project** — `scripts/claude.sh /workspace/tests`; confirm no `.git` directory
   is created on the host and the container starts normally.
6. **`.git`-as-file project** — point at a submodule/worktree checkout; confirm the warning
   and that the container still starts.
7. **Feature check** — `/code-review` inside the container completes; `claude --worktree`
   fails as expected.
8. **Regression** — the credential symlink work from the previous change still holds:
   `ls -l ~/.claude/.credentials.json` is a symlink into `~/.claude-auth` after the run.
