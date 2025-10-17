#!/bin/bash
# verify_hardening.sh — checks if server hardening applied correctly

echo "🔒 Verifying server hardening..."
echo "------------------------------------"

PASS=0
FAIL=0

check() {
  local desc="$1"
  local cmd="$2"
  local expected="$3"
  local success="$4"
  local failure="$5"

  if eval "$cmd" | grep -q "$expected"; then
    echo "✅ $success"
    ((PASS++))
  else
    echo "❌ $failure"
    ((FAIL++))
  fi
}

# 1. Root login disabled
check "Root login disabled" \
  "grep -E '^PermitRootLogin' /etc/ssh/sshd_config" \
  "no" \
  "Root SSH login is disabled" \
  "Root SSH login is NOT disabled"

# 2. Password authentication disabled
check "Password authentication disabled" \
  "grep -E '^PasswordAuthentication' /etc/ssh/sshd_config" \
  "no" \
  "Password authentication is disabled" \
  "Password authentication is still enabled"

# 3. Firewall active
if sudo ufw status | grep -q "Status: active"; then
  echo "✅ Firewall (UFW) is active"
  ((PASS++))
else
  echo "❌ Firewall (UFW) is NOT active"
  ((FAIL++))
fi

# 4. Allowed ports
echo "   Allowed ports:"
sudo ufw status | grep "ALLOW"

# 5. Fail2ban running
if systemctl is-active --quiet fail2ban; then
  echo "✅ fail2ban is running"
  ((PASS++))
else
  echo "⚠️ fail2ban is not running or not installed"
fi

# 6. Deploy user sudo privileges
if groups deploy | grep -q '\bsudo\b'; then
  echo "✅ 'deploy' user is in the sudo group"
  ((PASS++))
else
  echo "❌ 'deploy' user is NOT in the sudo group"
  ((FAIL++))
fi

# 7. SSH nonstandard port
PORT=$(grep "^Port " /etc/ssh/sshd_config | awk '{print $2}')
if [[ "$PORT" != "22" && -n "$PORT" ]]; then
  echo "✅ SSH is running on nonstandard port $PORT"
  ((PASS++))
else
  echo "⚠️ SSH is using default port 22"
fi

echo "------------------------------------"
echo "🧾 Summary Report:"
echo "✅ Passed: $PASS"
echo "❌ Failed: $FAIL"
echo "------------------------------------"

if [[ $FAIL -eq 0 ]]; then
  echo "🎉 All checks passed — your server appears securely hardened!"
else
  echo "⚠️ Some checks failed — review details above."
fi
