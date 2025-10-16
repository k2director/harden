#!/bin/bash
# Harden a fresh Ubuntu 22.04/24.04 droplet for Kamal + Docker deployment
# Safe to rerun. Tested on DigitalOcean & Hetzner default images.

set -euo pipefail
IFS=$'\n\t'

echo "🔒 Starting server hardening for Kamal..."

# --- 1. System update & base tools ---
apt update && apt upgrade -y
apt install -y ufw fail2ban unattended-upgrades apt-listchanges curl wget git htop vim

# --- 2. Add deploy user ---
if ! id "deploy" &>/dev/null; then
  adduser --disabled-password --gecos "" deploy
  usermod -aG sudo deploy
  mkdir -p /home/deploy/.ssh
  cp ~/.ssh/authorized_keys /home/deploy/.ssh/authorized_keys || true
  chmod 700 /home/deploy/.ssh
  chmod 600 /home/deploy/.ssh/authorized_keys
  chown -R deploy:deploy /home/deploy/.ssh
  echo "✅ Created user 'deploy'"
fi

# --- 2b. Give deploy passwordless sudo (needed for Kamal) ---
mkdir -p /etc/sudoers.d
echo "deploy ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/deploy
chmod 440 /etc/sudoers.d/deploy
echo "✅ Deploy user granted passwordless sudo"

# --- 3. SSH hardening ---
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
systemctl restart ssh

# --- 4. UFW firewall ---
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw allow 80,443/tcp
ufw --force enable
echo "✅ Firewall active (22, 80, 443 allowed)"

# --- 5. Fail2Ban basic config ---
systemctl enable fail2ban
systemctl start fail2ban

# --- 6. Install Docker ---
if ! command -v docker &>/dev/null; then
  apt install -y ca-certificates curl gnupg lsb-release
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
  apt update
  apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  usermod -aG docker deploy
  systemctl enable docker
  echo "✅ Docker installed"
fi

# --- 7. Docker daemon config ---
mkdir -p /etc/docker
cat >/etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "no-new-privileges": true,
  "live-restore": true
}
EOF
systemctl restart docker

# --- 8. Sysctl security hardening ---
cat >/etc/sysctl.d/99-kamal-hardening.conf <<'EOF'
# Network security
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.send_redirects=0
net.ipv4.conf.all.accept_source_route=0
net.ipv4.conf.default.accept_source_route=0
net.ipv4.icmp_echo_ignore_broadcasts=1
net.ipv4.icmp_ignore_bogus_error_responses=1
net.ipv4.tcp_syncookies=1
fs.protected_hardlinks=1
fs.protected_symlinks=1
EOF
sysctl --system

# --- 9. Enable unattended upgrades ---
dpkg-reconfigure -f noninteractive unattended-upgrades
systemctl enable unattended-upgrades

# --- 10. Docker log rotation (via logrotate) ---
cat >/etc/logrotate.d/docker-containers <<'EOF'
/var/lib/docker/containers/*/*.log {
    rotate 3
    daily
    compress
    missingok
    delaycompress
    copytruncate
}
EOF

echo "✅ Hardened successfully. Reboot recommended."
