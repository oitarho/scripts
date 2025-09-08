# 🚀 Scripts Collection

Набор скриптов для быстрого поднятия **production-ready окружения** на Ubuntu Server.  
Сюда входят:
- подготовка Docker,
- настройка Traefik (авто-HTTPS через Let’s Encrypt),
- базовый hardening (фаервол, fail2ban, sysctl).

---

## 📦 Установка и запуск

### Вариант A: через `git clone` + `Makefile` (рекомендуется)
```bash
git clone https://github.com/oitarho/scripts.git
cd scripts
make help
```

Посмотреть список команд:
```bash
make help
```

Запустить нужное:
```bash
make bootstrap-docker     # установить Docker
make setup-traefik        # развернуть Traefik + HTTPS
make hardening            # применить базовый hardening
make setup-all            # выполнить всё подряд
```

### Вариант B: напрямую через `curl` (без клонирования)

⚠️ Запускать от имени `root` или через `sudo`.

#### Подготовка Docker окружения
```bash
curl -fsSL https://raw.githubusercontent.com/oitarho/scripts/main/bootstrap-docker.sh | bash
```

#### Развёртывание Traefik + demo (whoami) с HTTPS
```bash
DOMAIN=example.com ACME_EMAIL=you@example.com \
curl -fsSL https://raw.githubusercontent.com/oitarho/scripts/main/setup-traefik.sh | bash
```

Дальше:
1. Создайте DNS A-запись: `whoami.<DOMAIN>` → IP сервера.  
2. Запустите стек:
   ```bash
   cd /srv/compose/reverse-proxy
   dcu
   ```
3. Проверьте: откройте `https://whoami.<DOMAIN>` — должен быть валидный сертификат Let’s Encrypt.

---

## 📜 Список скриптов

### 1. `bootstrap-docker.sh`
Готовит Docker окружение:
- Docker Engine + Buildx + Compose v2
- `/etc/docker/daemon.json`: log-rotation, buildkit, live-restore
- systemd hardening для `docker.service`
- UFW (SSH/80/443), Fail2ban, unattended-upgrades
- sysctl (ip_forward и базовые твики)
- алиасы: `dc`, `dcu`, `dcd`, `dcl`
- директории: `/srv/compose`, `/srv/data`, `/srv/logs`
- демо `whoami`

#### Проверка:
```bash
cd /srv/compose
dcu
curl http://<IP_сервера>/
```

---

### 2. `setup-traefik.sh`
Устанавливает **Traefik v3 + Let’s Encrypt**:
- авто-редирект HTTP → HTTPS
- автоматические сертификаты
- middleware: security headers, gzip, rate-limit
- сети: `web` (публичная), `internal` (приватная)
- демо-сервис: `whoami` по `https://whoami.<DOMAIN>`

Запуск:
```bash
make setup-traefik
```

Или в один шаг с подстановкой домена и email:
```bash
make deploy-whoami DOMAIN=example.com ACME_EMAIL=you@example.com
```

---

### 3. `hardening.sh`
Базовый **hardening**:
- UFW (deny incoming / allow outgoing, разрешены SSH/80/443)
- Fail2ban (защита SSH)
- sysctl: TCP syncookies, rp_filter, disable bogus ICMP
- SSH: мягкие рекомендации (root-доступ не отключается, чтобы не потерять доступ)

Запуск:
```bash
make hardening
```

---

## 🛠 Алиасы для работы с Compose

После установки доступны команды:
- `dc`  → `docker compose`
- `dcu` → `docker compose up -d --remove-orphans`
- `dcd` → `docker compose down --remove-orphans`
- `dcl` → `docker compose logs -f --tail=200`

---

## 📌 Полезное

- Добавление порта в UFW:
  ```bash
  ufw allow 5432/tcp
  ufw status
  ```

- Обновление контейнеров:
  ```bash
  docker compose pull && dcu
  ```

- Проверка статуса:
  ```bash
  docker info
  systemctl status docker
  fail2ban-client status sshd
  ufw status verbose
  ```

---

💡 Репозиторий удобно использовать как «каталог»: добавляйте новые скрипты в `scripts/` и регистрируйте их в `Makefile`, чтобы запускать одной командой.
