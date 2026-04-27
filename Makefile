# Vyogo Stack — developer conveniences.
# All state lives in docker-compose.yml + .env. This Makefile is just shortcuts.

SHELL := /usr/bin/env bash
COMPOSE := docker compose

.PHONY: help up down logs ps shell reset update build mcp-binary reload-frontend reload-agent reload-mcp

# The mcp Dockerfile expects a pre-built Linux binary at
# submodules/frappe-mcp-server/frappe-mcp-server (see commit baacaad in that
# repo). Build it on the host via the submodule's Makefile before docker build.
mcp-binary:
	$(MAKE) -C submodules/frappe-mcp-server build-linux

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
	@echo ""
	@echo "Hot-reload after editing source (skips bootstrap fingerprint cache):"
	@echo "  make reload-frontend  Recompile frappe_ai Vue bundle inside ERPNext + bench build"
	@echo "  make reload-agent     Rebuild + restart vyogo-agent (pip-installed Python)"
	@echo "  make reload-mcp       Rebuild Go binary + image + restart vyogo-mcp"

up: mcp-binary
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

build: mcp-binary
	$(COMPOSE) build

update: mcp-binary
	git submodule update --remote --merge
	$(COMPOSE) build
	$(COMPOSE) up -d

reset:
	@echo "This will DELETE all container data (ERPNext site, DB, logs, bootstrap state)."
	@read -p "Type 'reset' to confirm: " answer && [ "$$answer" = "reset" ] || (echo "aborted" && exit 1)
	$(COMPOSE) down -v
	@echo "reset complete — next 'make up' will re-bootstrap from scratch"

# Hot-reload targets. Bootstrap's fingerprint cache hashes compiled dist/
# files, so plain `docker compose up bootstrap` is a no-op when only source
# changes. These targets bypass it and force the rebuild path that actually
# picks up the new source.

reload-frontend:
	@echo "Rebuilding frappe_ai frontend bundle inside ERPNext container…"
	@# Compute the submodule's git short sha on the host (the container has
	@# no .git) and pass it through to vite's build-version stamp.
	@SHA=$$(git -C submodules/frappe_ai rev-parse --short HEAD 2>/dev/null || echo nogit); \
	DIRTY=$$(git -C submodules/frappe_ai status --porcelain 2>/dev/null); \
	if [ -n "$$DIRTY" ]; then SHA=$${SHA}-dirty; fi; \
	echo "  build sha: $$SHA"; \
	$(COMPOSE) exec -u frappe -e FRAPPE_AI_BUILD_SHA=$$SHA erpnext bash -c "cd /home/frappe/frappe-bench/apps/frappe_ai/frontend && npm run build && cd /home/frappe/frappe-bench && bench build --app frappe_ai"
	@echo "Done. Hard-refresh browser (Cmd-Shift-R) to pick up the new bundle."

reload-agent:
	@echo "Rebuilding vyogo-agent image and restarting…"
	$(COMPOSE) build agent
	$(COMPOSE) up -d --force-recreate agent
	@echo "Done."

reload-mcp: mcp-binary
	@echo "Rebuilding vyogo-mcp image and restarting…"
	$(COMPOSE) build mcp
	$(COMPOSE) up -d --force-recreate mcp
	@echo "Done."
