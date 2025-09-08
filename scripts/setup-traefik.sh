#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "[ERR] Ошибка на строке $LINENO" >&2' ERR

[[ "${EUID:-$(id -u)}" -eq 0 ]] || { echo "[ERR] Запустите как root"; exit 1; }
command -v docker >/dev/null || { echo "[ERR] Docker не установлен (сначала запустите bootstrap-docker)"; exit 1; }

mkdir -p /srv/compose/reverse-proxy /srv/traefik/letsencrypt
touch /srv/traefik/letsencrypt/acme.json
chmod 600 /srv/traefik/letsencrypt/acme.json

COMPOSE_FILE=/srv/compose/reverse-proxy/docker-compose.yml
ENV_FILE=/srv/compose/reverse-proxy/.env

# Если переменные переданы извне — сразу создаём/перезаписываем .env
if [[ -n "${DOMAIN:-}" && -n "${ACME_EMAIL:-}" ]]; then
  cat > "$ENV_FILE" <<EOF
ACME_EMAIL=${ACME_EMAIL}
DOMAIN=${DOMAIN}
EOF
  echo "[OK] .env создан: DOMAIN=${DOMAIN}, ACME_EMAIL=${ACME_EMAIL}"
else
  # Иначе не трогаем существующий .env, а если нет — создаём с заглушками
  if [[ ! -f "$ENV_FILE" ]]; then
    cat > "$ENV_FILE" <<'ENV'
# Email для Let's Encrypt уведомлений
ACME_EMAIL=you@example.com
# Базовый домен (без поддоменов)
DOMAIN=example.com
ENV
    echo "[INFO] .env создан с заглушками (отредактируйте: $ENV_FILE)"
  else
    echo "[INFO] .env уже существует: $ENV_FILE"
  fi
fi

# Пишем docker-compose.yml
cat > "$COMPOSE_FILE" <<'YML'
version: "3.9"

networks:
  web:
    name: web
    driver: bridge
    external: false
  internal:
    name: internal
    driver: bridge
    internal: true

services:
  traefik:
    image: traefik:v3.1
    container_name: traefik
    restart: unless-stopped
    networks:
      - web
      - internal
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - /srv/traefik/letsencrypt:/letsencrypt
    command:
      - --providers.docker=true
      - --providers.docker.exposedbydefault=false
      - --entrypoints.web.address=:80
      - --entrypoints.web.http.redirections.entryPoint.to=websecure
      - --entrypoints.web.http.redirections.entryPoint.scheme=https
      - --entrypoints.websecure.address=:443
      - --certificatesresolvers.le.acme.email=${ACME_EMAIL}
      - --certificatesresolvers.le.acme.storage=/letsencrypt/acme.json
      - --certificatesresolvers.le.acme.httpchallenge=true
      - --certificatesresolvers.le.acme.httpchallenge.entrypoint=web
      - --api.dashboard=false
      - --log.level=INFO
    labels:
      - traefik.enable=true
      - traefik.http.middlewares.secure-headers.headers.stsSeconds=31536000
      - traefik.http.middlewares.secure-headers.headers.stsPreload=true
      - traefik.http.middlewares.secure-headers.headers.stsIncludeSubdomains=true
      - traefik.http.middlewares.secure-headers.headers.forceSTSHeader=true
      - traefik.http.middlewares.secure-headers.headers.referrerPolicy=no-referrer
      - traefik.http.middlewares.secure-headers.headers.frameDeny=true
      - traefik.http.middlewares.secure-headers.headers.contentTypeNosniff=true
      - traefik.http.middlewares.ratelimit.ratelimit.average=100
      - traefik.http.middlewares.ratelimit.ratelimit.burst=200
      - traefik.http.middlewares.gzip.compress=true

  whoami:
    image: traefik/whoami
    container_name: whoami
    restart: unless-stopped
    networks:
      - web
      - internal
    labels:
      - traefik.enable=true
      - traefik.http.routers.whoami.rule=Host(`whoami.${DOMAIN}`)
      - traefik.http.routers.whoami.entrypoints=websecure
      - traefik.http.routers.whoami.tls.certresolver=le
      - traefik.http.routers.whoami.middlewares=secure-headers@docker,ratelimit@docker,gzip@docker
      - traefik.http.services.whoami.loadbalancer.server.port=80
YML

echo "[OK] Traefik compose-шаблон установлен: $COMPOSE_FILE"
echo "Дальше:"
echo "  1) Если не передавали переменные — отредактируйте $ENV_FILE (ACME_EMAIL, DOMAIN)"
echo "  2) Создайте DNS A-запись: whoami.\$DOMAIN -> IP сервера"
echo "  3) Запустите: cd /srv/compose/reverse-proxy && dcu"
echo "  4) Проверьте: https://whoami.\$DOMAIN (сертификат подтянется автоматически)"
