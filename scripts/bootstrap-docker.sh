#!/usr/bin/env bash
# Production Docker bootstrap for Ubuntu Server
# Safe to re-run. Tested on Ubuntu 20.04/22.04/24.04.
set -Eeuo pipefail

### -------- Helpers --------
log()  { printf "\e[1;32m[OK]\e[0m %s\n" "$*"; }
warn() { printf "\e[1;33m[WARN]\e[0m %s\n" "$*" >&2; }
err()  { printf "\e[1;31m[ERR]\e[0m %s\n" "$*" >&2; }
trap 'err "Произошла ошибка на строке $LINENO"; exit 1' ERR

[[ "${EUID:-$(id -u)}" -eq 0 ]] || { err "Запустите как root"; exit 1; }

if ! command -v lsb_release >/dev/null 2>&1; then
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y lsb-release
fi

UBU_CODENAME="$(lsb_release -cs || true)"
UBU_ID="$(lsb_release -is 2>/dev/null || echo Ubuntu)"
[[ "$UBU_ID" == "Ubuntu" ]] || { err "Поддерживается только Ubuntu"; exit 1; }

export DEBIAN_FRONTEND=noninteractive

### -------- Base packages --------
apt-get update -y
apt-get install -y \
  ca-certificates curl gnupg apt-transport-https software-properties-common \
  ufw fail2ban unattended-upgrades jq

log "Базовые пакеты установлены"

### -------- Docker repo & install --------
install_docker_repo() {
  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
  fi
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu ${UBU_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
}
install_docker_repo

apt-get update -y
apt-get install -y \
  docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin
log "Docker Engine + Buildx + Compose v2 установлены"

### -------- Docker daemon config --------
install -d -m 0755 /etc/docker
DAEMON_JSON=/etc/docker/daemon.json

# Базовая безопасная конфигурация
read -r -d '' BASE_DAEMON_CFG <<'JSON' || true
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "exec-opts": ["native.cgroupdriver=systemd"],
  "features": { "buildkit": true },
  "live-restore": true,
  "userland-proxy": false,
  "icc": false,
  "default-address-pools": [
    { "base": "10.200.0.0/16", "size": 24 }
  ]
}
JSON

# Аккуратно смержим с существующим (если есть)
if [[ -s "$DAEMON_JSON" ]]; then
  TMP=$(mktemp)
  jq -s '.[0] * .[1]' <(echo "$BASE_DAEMON_CFG") "$DAEMON_JSON" > "$TMP" || {
    warn "jq merge не удался, перезаписываю daemon.json"
    echo "$BASE_DAEMON_CFG" > "$DAEMON_JSON"
  }
  [[ -s "$TMP" ]] && mv "$TMP" "$DAEMON_JSON"
else
  echo "$BASE_DAEMON_CFG" > "$DAEMON_JSON"
fi
log "Сконфигурирован /etc/docker/daemon.json"

### -------- Systemd hardening for docker.service --------
install -d /etc/systemd/system/docker.service.d
cat >/etc/systemd/system/docker.service.d/override.conf <<'CONF'
[Service]
# Увеличим лимиты и устойчивость
LimitNOFILE=1048576
LimitNPROC=1048576
TasksMax=infinity
Restart=always
RestartSec=3
# Жёстче sandboxing (совместимо с Docker)
NoNewPrivileges=yes
ProtectKernelTunables=yes
ProtectControlGroups=no
ProtectHome=yes
ProtectSystem=full
AmbientCapabilities=
CONF

systemctl daemon-reload
systemctl enable --now docker
systemctl restart docker
log "Docker запущен и включён в автозагрузку"

### -------- Enable IP forwarding (нужно для bridge-сетей) --------
SYSCTL_FILE=/etc/sysctl.d/99-docker.conf
cat >"$SYSCTL_FILE"<<'SYS'
net.ipv4.ip_forward=1
net.ipv4.tcp_syncookies=1
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
net.ipv6.conf.all.disable_ipv6=0
SYS
sysctl --system >/dev/null
log "Сетевой sysctl применён"

### -------- UFW firewall (SSH + 80/443 по умолчанию) --------
if ! ufw status | grep -q "Status: active"; then
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow OpenSSH
  # Разрешим стандартные web-порты (можете удалить, если не нужно)
  ufw allow 80/tcp
  ufw allow 443/tcp
  yes | ufw enable
  log "UFW включён (SSH/80/443 разрешены)"
else
  warn "UFW уже активен — пропускаю настройку правил"
fi

### -------- Fail2ban (SSH защита по умолчанию) --------
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
  systemctl enable --now fail2ban
  log "Fail2ban установлен и запущен"
else
  systemctl restart fail2ban
  log "Fail2ban уже настроен — перезапущен"
fi

### -------- Unattended upgrades --------
apt-get install -y unattended-upgrades
cat >/etc/apt/apt.conf.d/20auto-upgrades <<'APT'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT
log "Включены автообновления безопасности (unattended-upgrades)"

### -------- Useful docker helpers --------
install -m 0755 /dev/null /usr/local/bin/dc
cat >/usr/local/bin/dc <<'SH'
#!/usr/bin/env bash
set -euo pipefail
exec docker compose "$@"
SH

install -m 0755 /dev/null /usr/local/bin/dcu
cat >/usr/local/bin/dcu <<'SH'
#!/usr/bin/env bash
set -euo pipefail
exec docker compose up -d --remove-orphans "$@"
SH

install -m 0755 /dev/null /usr/local/bin/dcd
cat >/usr/local/bin/dcd <<'SH'
#!/usr/bin/env bash
set -euo pipefail
exec docker compose down --remove-orphans "$@"
SH

install -m 0755 /dev/null /usr/local/bin/dcl
cat >/usr/local/bin/dcl <<'SH'
#!/usr/bin/env bash
set -euo pipefail
exec docker compose logs -f --tail=200 "$@"
SH
log "CLI-хелперы: dc, dcu, dcd, dcl"

### -------- Project skeleton --------
install -d -m 0755 /srv/{compose,data,logs}
if [[ ! -f /srv/compose/docker-compose.yml ]]; then
  cat > /srv/compose/docker-compose.yml <<'YML'
services:
  whoami:
    image: traefik/whoami
    container_name: whoami
    networks: [web]
    deploy:
      resources:
        limits:
          cpus: "0.50"
          memory: 256M
    restart: unless-stopped

networks:
  web:
    name: web
    driver: bridge
YML
  log "Шаблон /srv/compose/docker-compose.yml создан (demo сервис whoami)"
fi

### -------- Compose bash completion (если доступно) --------
if command -v docker >/dev/null 2>&1; then
  COMPD=/etc/bash_completion.d
  if [[ -d "$COMPD" ]]; then
    docker completion bash > "$COMPD/docker"
    docker compose completion bash > "$COMPD/docker-compose"
    log "Bash completion для docker и compose установлен"
  fi
fi

### -------- Summary --------
cat <<'OUT'

Готово ✅

Установлено и настроено:
  - Docker Engine + Buildx + Compose v2
  - /etc/docker/daemon.json: log-rotation, BuildKit, live-restore
  - systemd hardening для docker.service
  - UFW (SSH/80/443), Fail2ban
  - Unattended security upgrades
  - Sysctl для ip_forward и сетевой безопасности
  - Директории: /srv/compose, /srv/data, /srv/logs
  - Хелперы: dc / dcu / dcd / dcl

Быстрый старт:
  cd /srv/compose
  dcu
  # затем: curl http://<SERVER_IP>/  (вернётся заголовок от demo 'whoami')

Советы:
  - Положите свои compose-файлы в /srv/compose и запускайте 'dcu'.
  - Для production domain + TLS добавьте Traefik/Caddy как reverse proxy.
  - Проверьте 'ufw status' и откройте нужные порты под ваши сервисы.

OUT
