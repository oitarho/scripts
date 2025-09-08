# === Makefile для набора серверных скриптов ===
# Запуск: make help

SHELL := /bin/bash
SCRIPTS_DIR := scripts
REPO := https://raw.githubusercontent.com/oitarho/scripts/main

# Утилита: проверка/разрешение прав на исполняемость локального скрипта
define require_script
	@if [[ ! -x "$(SCRIPTS_DIR)/$(1)" && -f "$(SCRIPTS_DIR)/$(1)" ]]; then chmod +x "$(SCRIPTS_DIR)/$(1)"; fi
	@if [[ ! -f "$(SCRIPTS_DIR)/$(1)" ]]; then echo "Файл $(SCRIPTS_DIR)/$(1) не найден"; exit 1; fi
endef

## Подготовить production-ready Docker окружение (локально из ./scripts)
bootstrap-docker:
	$(call require_script,bootstrap-docker.sh)
	sudo -E $(SCRIPTS_DIR)/bootstrap-docker.sh

## Установить и настроить Traefik + Let's Encrypt (локально из ./scripts)
setup-traefik:
	$(call require_script,setup-traefik.sh)
	sudo -E $(SCRIPTS_DIR)/setup-traefik.sh

## Базовый hardening: UFW, Fail2ban, SSH-рекомендации, sysctl (локально из ./scripts)
hardening:
	$(call require_script,hardening.sh)
	sudo -E $(SCRIPTS_DIR)/hardening.sh

## Запустить все шаги подряд (локально)
setup-all: bootstrap-docker setup-traefik hardening

## Развернуть Traefik + whoami через удалённый скрипт, с автоподстановкой DOMAIN/EMAIL
## Использование: make deploy-whoami DOMAIN=example.com ACME_EMAIL=you@example.com
deploy-whoami:
	@if [ -z "$(DOMAIN)" ] || [ -z "$(ACME_EMAIL)" ]; then \
		echo "Usage: make deploy-whoami DOMAIN=example.com ACME_EMAIL=you@example.com"; \
		exit 1; \
	fi
	curl -fsSL $(REPO)/setup-traefik.sh | DOMAIN=$(DOMAIN) ACME_EMAIL=$(ACME_EMAIL) bash

## Показать список доступных команд
help:
	@echo "Доступные команды:"
	@grep -E '^##' Makefile | sed -e 's/## //'
	@grep -E '^[a-zA-Z0-9_.-]+:.*?##' Makefile \
	  | sed -e 's/:.*##/: /' \
	  | column -t -s:

.PHONY: bootstrap-docker setup-traefik hardening setup-all deploy-whoami help
