FROM archlinux:base

ARG UID=1000
ARG GID=1000

# Chaotic-AUR: prebuilt AUR packages via pacman (yay/paru would need makepkg and a
# writable git; the git here is wrapped read-only, see below)
RUN pacman-key --init \
 && pacman-key --recv-key 3056513887B78AEB --keyserver keyserver.ubuntu.com \
 && pacman-key --lsign-key 3056513887B78AEB \
 && pacman -U --noconfirm \
      https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst \
      https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst \
 && printf '\n[chaotic-aur]\nInclude = /etc/pacman.d/chaotic-mirrorlist\n' >> /etc/pacman.conf \
 && pacman -Syu --noconfirm sudo curl git \
 && pacman -Scc --noconfirm

# non-root user matching the host uid so bind-mounted files keep their owner
RUN groupadd -g "$GID" claude && useradd -m -u "$UID" -g "$GID" claude \
 && echo 'claude ALL=(ALL) NOPASSWD: /usr/bin/pacman' > /etc/sudoers.d/claude

USER claude
ENV PATH=/home/claude/.local/bin:$PATH \
    GIT_OPTIONAL_LOCKS=0 \
    GIT_TERMINAL_PROMPT=0 \
    GIT_ASKPASS=/bin/false \
    SSH_ASKPASS=/bin/false \
    CLAUDE_CONFIG_DIR=/home/claude/.claude
RUN curl -fsSL https://claude.ai/install.sh | bash

RUN mkdir -p /home/claude/.claude /home/claude/.claude-auth /home/claude/.cache/git

# read-only git: wrapper ahead of /usr/bin/git in PATH, and a system config with no
# credential helper. Neither is a boundary (see README); the read-only .git mount is.
USER root
COPY scripts/git-ro /usr/local/bin/git
RUN chmod 0755 /usr/local/bin/git \
 && printf "[safe]\\n\\tdirectory = /workspace\\n" > /etc/gitconfig
USER claude

WORKDIR /workspace
CMD ["sleep", "infinity"]
