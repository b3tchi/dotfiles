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

# Create test user with SSH key auth
RUN useradd -m -s /bin/bash testuser && \
    echo 'testuser:test' | chpasswd && \
    mkdir -p /home/testuser/.ssh && \
    mkdir -p /home/testuser/.local/bin && \
    mkdir -p /home/testuser/.dotfiles/tmux && \
    mkdir -p /home/testuser/.config/nushell

# Generate SSH keypair (shared across containers via volume)
RUN ssh-keygen -t ed25519 -f /home/testuser/.ssh/id_ed25519 -N '' && \
    cp /home/testuser/.ssh/id_ed25519.pub /home/testuser/.ssh/authorized_keys && \
    chown -R testuser:testuser /home/testuser

# Disable strict host checking for test convenience
RUN echo 'Host *\n  StrictHostKeyChecking no\n  UserKnownHostsFile /dev/null' > /home/testuser/.ssh/config && \
    chmod 600 /home/testuser/.ssh/config && \
    chown testuser:testuser /home/testuser/.ssh/config

EXPOSE 22

CMD ["/usr/sbin/sshd", "-D"]
