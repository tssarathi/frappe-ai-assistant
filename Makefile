# Vyogo Stack — developer conveniences.
# All state lives in docker-compose.yml + .env. This Makefile is just shortcuts.

SHELL := /usr/bin/env bash
COMPOSE := docker compose

.PHONY: help up down logs ps shell reset update build

help:
	@echo "Vyogo Stack targets:"
	@echo "  make up       Build + start all services (first run: also bootstraps frappe_ai)"
	@echo "  make down     Stop and remove containers (volumes preserved)"
	@echo "  make logs     Tail logs for all services. Use SVC=<name> to scope (e.g. make logs SVC=agent)"
	@echo "  make ps       Show container status"
	@echo "  make shell    Open a bash shell in the erpnext container"
	@echo "  make reset    DESTRUCTIVE. Remove containers + volumes for a clean first-boot"
	@echo "  make update   Pull submodule updates, then rebuild"
	@echo "  make build    Rebuild images without starting"

up:
	@test -f .env || (echo "error: .env not found. Run: cp .env.example .env" && exit 1)
	$(COMPOSE) up -d --build

down:
	$(COMPOSE) down

logs:
ifdef SVC
	$(COMPOSE) logs -f $(SVC)
else
	$(COMPOSE) logs -f
endif

ps:
	$(COMPOSE) ps

shell:
	$(COMPOSE) exec erpnext bash

build:
	$(COMPOSE) build

update:
	git submodule update --remote --merge
	$(COMPOSE) build
	$(COMPOSE) up -d

reset:
	@echo "This will DELETE all container data (ERPNext site, DB, logs, bootstrap state)."
	@read -p "Type 'reset' to confirm: " answer && [ "$$answer" = "reset" ] || (echo "aborted" && exit 1)
	$(COMPOSE) down -v
	@echo "reset complete — next 'make up' will re-bootstrap from scratch"
