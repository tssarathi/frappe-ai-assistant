#!/usr/bin/env bash
# First-boot bootstrap for the Vyogo orchestrator.
# Idempotent: flag file at /home/frappe/frappe-bench/sites/.vyogo_bootstrapped
# indicates the work has already been done.

set -euo pipefail

SITE="${SITE_NAME:-erpnext.local}"
FLAG_FILE="/home/frappe/frappe-bench/sites/.vyogo_bootstrapped"
APP_PATH="/home/frappe/frappe-bench/apps/frappe_ai"
ERPNEXT_URL="${ERPNEXT_URL:-http://erpnext:8000}"
AGENT_URL_DEFAULT="${AGENT_URL_DEFAULT:-http://localhost:8484}"

log() { printf '[bootstrap] %s\n' "$*" >&2; }

if [ -f "$FLAG_FILE" ]; then
  log "flag file present at $FLAG_FILE — nothing to do"
  exit 0
fi

log "waiting for ERPNext at $ERPNEXT_URL ..."
for i in $(seq 1 120); do
  if curl -fsS -o /dev/null "$ERPNEXT_URL"; then
    log "ERPNext is up (attempt $i)"
    break
  fi
  sleep 5
  if [ "$i" -eq 120 ]; then
    log "ERPNext did not become reachable within 10 minutes — aborting"
    exit 1
  fi
done

log "verifying frappe_ai app is bind-mounted at $APP_PATH"
if [ ! -d "$APP_PATH" ]; then
  log "ERROR: $APP_PATH not found — is the bind mount configured in docker-compose.yml?"
  exit 1
fi

cd /home/frappe/frappe-bench

log "registering frappe_ai with bench"
bench get-app --skip-assets "file://$APP_PATH" || log "get-app returned non-zero (likely already registered) — continuing"

log "installing frappe_ai into site $SITE"
bench --site "$SITE" install-app frappe_ai

log "building frappe_ai assets"
bench build --app frappe_ai

log "seeding MCP Server Settings (enabled=1, agent_url=$AGENT_URL_DEFAULT)"
bench --site "$SITE" execute frappe.client.set_value \
  --kwargs "{\"doctype\": \"MCP Server Settings\", \"name\": \"MCP Server Settings\", \"fieldname\": {\"enabled\": 1, \"agent_url\": \"$AGENT_URL_DEFAULT\", \"timeout\": 30}}"

log "writing flag file at $FLAG_FILE"
touch "$FLAG_FILE"

log "done"
