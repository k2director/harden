#!/bin/bash
# post-clone-harden.sh
# Run this on each freshly cloned VM from your template
# Assumes Docker, fail2ban, and base hardening are already in the template
set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────
# Set these before running the script
RESEND_API_KEY="re_your_key_here"
ALERT_EMAIL="your@email.com"
DISK_THRESHOLD=80   # Alert when disk usage exceeds this percentage
# ──────────────────────────────────────────────────────────────────────────

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

# --- 7. Unattended security upgrades ---
sudo apt-get install -y unattended-upgrades > /dev/null 2>&1
sudo tee /etc/apt/apt.conf.d/50unattended-upgrades > /dev/null <<'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF
sudo tee /etc/apt/apt.conf.d/20auto-upgrades > /dev/null <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
echo "✅ Unattended security upgrades configured"

# --- 8. Disk space alerting ---
sudo tee /usr/local/bin/check-disk-space.sh > /dev/null <<DISKSCRIPT
#!/bin/bash
THRESHOLD=${DISK_THRESHOLD}
RESEND_API_KEY="${RESEND_API_KEY}"
ALERT_EMAIL="${ALERT_EMAIL}"
HOSTNAME=\$(hostname)

USAGE=\$(df / | awk 'NR==2 {print \$5}' | tr -d '%')

if [ "\$USAGE" -gt "\$THRESHOLD" ]; then
  curl -s -X POST https://api.resend.com/emails \\
    -H "Authorization: Bearer \$RESEND_API_KEY" \\
    -H "Content-Type: application/json" \\
    -d "{
      \"from\": \"onboarding@resend.dev\",
      \"to\": \"\$ALERT_EMAIL\",
      \"subject\": \"⚠️ Disk Space Warning on \$HOSTNAME\",
      \"text\": \"Disk usage on \$HOSTNAME has reached \${USAGE}% (threshold: \${THRESHOLD}%).\n\nRun 'df -h' to investigate.\"
    }"
fi
DISKSCRIPT

sudo chmod +x /usr/local/bin/check-disk-space.sh

# Add to deploy user's crontab (runs daily at 8am)
(crontab -u deploy -l 2>/dev/null | grep -v "check-disk-space"; \
  echo "0 8 * * * /usr/local/bin/check-disk-space.sh") | sudo crontab -u deploy -
echo "✅ Disk space alerting configured (threshold: ${DISK_THRESHOLD}%)"

# --- 9. Backup log rotation ---
sudo tee /etc/logrotate.d/backup-db > /dev/null <<'EOF'
/var/log/backup-db.log {
    rotate 14
    weekly
    compress
    missingok
    delaycompress
    copytruncate
    notifempty
}
EOF
echo "✅ Backup log rotation configured (14 weeks)"

echo ""
echo "✅ Post-clone hardening complete!"
echo "⚠️  IMPORTANT: SSH is now hardened. Make sure you can log in as 'deploy' before logging out!"
echo ""
echo "Test with: ssh deploy@\$(hostname -I | awk '{print \$1}')"
