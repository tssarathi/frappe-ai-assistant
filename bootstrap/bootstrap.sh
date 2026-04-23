#!/usr/bin/env bash
# First-boot bootstrap for the Vyogo orchestrator.
# Idempotent: flag file at /home/frappe/frappe-bench/sites/.vyogo_bootstrapped
# indicates the work has already been done.

set -euo pipefail

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

# Auto-detect the actual site name (the image may create a different name than SITE_NAME).
# The sites/ directory contains: apps.json, apps.txt, assets, common_site_config.json, <site-dir>
SITE="${SITE_NAME:-erpnext.local}"
if [ ! -d "sites/$SITE" ]; then
  log "site '$SITE' not found; auto-detecting from sites/ directory ..."
  DETECTED=$(find sites/ -maxdepth 1 -mindepth 1 -type d | grep -v '^sites/assets$' | head -1 | xargs basename 2>/dev/null || true)
  if [ -z "$DETECTED" ]; then
    log "ERROR: could not auto-detect site — aborting"
    exit 1
  fi
  log "using detected site: $DETECTED"
  SITE="$DETECTED"
fi

log "target site: $SITE"

# Patch common_site_config.json so bench commands in this container can
# reach the erpnext container's MariaDB and Redis over the Docker network.
# We save the original and restore it on exit so erpnext is not affected.
COMMON_CFG="sites/common_site_config.json"
COMMON_CFG_BAK="${COMMON_CFG}.bootstrap_bak"

restore_cfg() {
  if [ -f "$COMMON_CFG_BAK" ]; then
    log "restoring original common_site_config.json"
    mv "$COMMON_CFG_BAK" "$COMMON_CFG"
  fi
}
trap restore_cfg EXIT

cp "$COMMON_CFG" "$COMMON_CFG_BAK"
log "patching common_site_config.json for cross-container DB/Redis access"
python3 - <<'PYEOF'
import json, sys

with open("sites/common_site_config.json") as f:
    cfg = json.load(f)

# Point DB at the erpnext container (MariaDB exposes root@% after its init script).
cfg["db_host"] = "erpnext"
cfg["db_port"] = 3306

# Point Redis at the erpnext container.
for key in ("redis_cache", "redis_queue", "redis_socketio"):
    cfg[key] = "redis://erpnext:6379"

with open("sites/common_site_config.json", "w") as f:
    json.dump(cfg, f, indent=1)

print("[bootstrap] common_site_config.json patched", file=sys.stderr)
PYEOF

log "pip-installing frappe_ai into bench virtualenv"
./env/bin/pip install -q -e "$APP_PATH"

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
