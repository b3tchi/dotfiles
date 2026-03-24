FROM archlinux:latest

# Install nushell, tmux, openssh
RUN pacman -Syu --noconfirm && \
    pacman -S --noconfirm nushell tmux openssh && \
    pacman -Scc --noconfirm

# Configure SSH server
RUN ssh-keygen -A && \
    echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config && \
    echo 'PasswordAuthentication yes' >> /etc/ssh/sshd_config && \
    echo 'root:test' | chpasswd

# Create test user
RUN useradd -m -s /bin/bash testuser && \
    echo 'testuser:test' | chpasswd && \
    mkdir -p /home/testuser/.ssh && \
    mkdir -p /home/testuser/.local/bin && \
    mkdir -p /home/testuser/.dotfiles/tmux && \
    mkdir -p /home/testuser/.config/nushell

# Generate SSH keypair at build time (will be copied by entrypoint)
RUN ssh-keygen -t ed25519 -f /tmp/id_ed25519 -N ''

# Disable strict host checking for test convenience
RUN printf 'Host *\n  StrictHostKeyChecking no\n  UserKnownHostsFile /dev/null\n' > /home/testuser/.ssh/config && \
    chmod 700 /home/testuser/.ssh && \
    chmod 600 /home/testuser/.ssh/config && \
    chown -R testuser:testuser /home/testuser

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 22

ENTRYPOINT ["/entrypoint.sh"]
