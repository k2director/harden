#!/bin/bash
# post-clone-harden.sh
# Run this on each freshly cloned VM from your template
# Assumes Docker, fail2ban, and base hardening are already in the template

set -euo pipefail

echo "🔒 Running post-clone hardening..."

# --- 1. Add deploy user ---
if ! id "deploy" &>/dev/null; then
  sudo adduser --disabled-password --gecos "" deploy
  sudo usermod -aG sudo deploy
  sudo usermod -aG docker deploy
  sudo mkdir -p /home/deploy/.ssh
  sudo cp ~/.ssh/authorized_keys /home/deploy/.ssh/authorized_keys 2>/dev/null || echo "⚠️  No SSH keys found to copy"
  sudo chmod 700 /home/deploy/.ssh
  sudo chmod 600 /home/deploy/.ssh/authorized_keys 2>/dev/null || true
  sudo chown -R deploy:deploy /home/deploy/.ssh
  echo "✅ Created user 'deploy'"
fi

# --- 2. Give deploy passwordless sudo (needed for Kamal) ---
sudo mkdir -p /etc/sudoers.d
echo "deploy ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/deploy
sudo chmod 440 /etc/sudoers.d/deploy
echo "✅ Deploy user granted passwordless sudo"

# --- 3. SSH hardening ---
sudo sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
sudo systemctl restart ssh
echo "✅ SSH hardened"

# --- 4. UFW firewall ---
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow OpenSSH
sudo ufw allow 80,443/tcp
sudo ufw --force enable
echo "✅ Firewall active (22, 80, 443 allowed)"

# --- 5. Start fail2ban ---
sudo systemctl enable fail2ban
sudo systemctl start fail2ban
echo "✅ Fail2ban active"

# --- 6. Docker log rotation ---
sudo tee /etc/logrotate.d/docker-containers > /dev/null <<'EOF'
/var/lib/docker/containers/*/*.log {
    rotate 3
    daily
    compress
    missingok
    delaycompress
    copytruncate
}
EOF
echo "✅ Docker log rotation configured"

echo ""
echo "✅ Post-clone hardening complete!"
echo "⚠️  IMPORTANT: SSH is now hardened. Make sure you can log in as 'deploy' before logging out!"
echo ""
echo "Test with: ssh deploy@\$(hostname -I | awk '{print \$1}')"
