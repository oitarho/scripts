#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "[ERR] Ошибка на строке $LINENO" >&2' ERR

[[ "${EUID:-$(id -u)}" -eq 0 ]] || { echo "[ERR] Запустите как root"; exit 1; }
export DEBIAN_FRONTEND=noninteractive

# Базовые пакеты
apt-get update -y
apt-get install -y ufw fail2ban

# UFW: deny incoming / allow outgoing + SSH/80/443
if ! ufw status | grep -q "Status: active"; then
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow OpenSSH
  ufw allow 80/tcp
  ufw allow 443/tcp
  yes | ufw enable
  echo "[OK] UFW включён"
else
  echo "[INFO] UFW уже активен"
fi

# Fail2ban: базовый jail для sshd
JAIL_LOCAL=/etc/fail2ban/jail.local
if [[ ! -f "$JAIL_LOCAL" ]]; then
  cat >"$JAIL_LOCAL"<<'JAIL'
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
backend = systemd

[sshd]
enabled = true
JAIL
fi
systemctl enable --now fail2ban
echo "[OK] Fail2ban настроен и запущен"

# Щадящие sysctl
SYSCTL_FILE=/etc/sysctl.d/60-hardening.conf
cat >"$SYSCTL_FILE"<<'SYS'
net.ipv4.tcp_syncookies=1
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
net.ipv4.icmp_echo_ignore_broadcasts=1
net.ipv4.icmp_ignore_bogus_error_responses=1
kernel.kptr_restrict=1
kernel.dmesg_restrict=1
SYS
sysctl --system >/dev/null
echo "[OK] Sysctl применён"

# SSH: только рекомендации (не ломаем доступ!)
SSHD=/etc/ssh/sshd_config.d/99-hardening.conf
if [[ ! -f "$SSHD" ]]; then
  cat > "$SSHD" <<'SSH'
# Рекомендация: используйте ключи. Эти параметры оставлены мягкими,
# чтобы не отрезать доступ, если пока только пароль.
# PasswordAuthentication yes
# PermitRootLogin prohibit-password
# PubkeyAuthentication yes
# MaxAuthTries 4
# LoginGraceTime 30
SSH
  echo "[INFO] Рекомендации по SSH записаны в $SSHD (не активированы). Проверьте ключи и включите при готовности."
fi
systemctl reload ssh || true

echo "Готово ✅  (UFW, Fail2ban, sysctl; SSH — рекомендации без рисков)"
