#!/usr/bin/env bash
# First-boot bootstrap for the Vyogo orchestrator.
# Idempotent: flag file at /home/frappe/frappe-bench/sites/.vyogo_bootstrapped
# indicates the work has already been done.

set -euo pipefail

# When the container starts as root (Dockerfile entrypoint), fix permissions
# on the node_modules named-volume mount (Docker creates it root-owned, but
# everything else here runs as the frappe user) and re-exec as frappe.
if [ "$(id -u)" = "0" ]; then
  NM=/home/frappe/frappe-bench/apps/frappe_ai/frontend/node_modules
  if [ -d "$NM" ]; then
    # The vyogo/erpnext image puts the frappe user (UID 1001) in the root
    # group (GID 0), with no `frappe` group — chown must use root as the
    # group, matching the existing ownership of the surrounding files.
    chown -R frappe:root "$NM"
  fi
  # Use `runuser -u` (no -l) so PATH stays as the image set it — that PATH
  # includes /var/lib/redis/.local/bin where `bench` lives. `runuser -l`
  # would reset to a default login PATH that drops bench.
  # We must also force HOME=/var/lib/redis: the vyogo/erpnext image installs
  # bench's Python package into /var/lib/redis/.local/lib (treating that as
  # the frappe user's effective home, despite /etc/passwd saying /home/frappe).
  # Without this, `bench` resolves but its `from bench.cli import cli` import
  # fails with ModuleNotFoundError because Python's user-site path uses HOME.
  # -- preserves argv passthrough.
  exec runuser -u frappe -- env HOME=/var/lib/redis /usr/local/bin/bootstrap.sh "$@"
fi

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

# Auto-detect the actual site name. In practice the vyogo/erpnext image creates
# a site named dev.localhost and ignores SITE_NAME, so the env var is a hint
# only — the detect-from-disk branch below is what fires on the default image.
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
  if [ ! -f "$COMMON_CFG_BAK" ]; then
    return 0
  fi
  log "restoring original common_site_config.json"
  if ! mv "$COMMON_CFG_BAK" "$COMMON_CFG"; then
    # If this fails the ERPNext container is left with our cross-container
    # db/redis patches and won't boot cleanly — log loudly so the operator
    # sees it even if the main script already exited successfully.
    log "ERROR: failed to restore $COMMON_CFG from $COMMON_CFG_BAK — the ERPNext container will need manual recovery"
    return 1
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

# Build the Vite-based chat UI. frappe_ai/ contains TWO frontends:
#   - frappe_ai/public/            — small sidebar CSS/JS, built by `bench build`
#   - frappe_ai/frontend/          — the full Vue/Vite chat app, served from
#                                    frontend/dist/ and referenced by hooks.py
# `bench build` does NOT run `vite build`, so we must do it explicitly here.
# `npm run build` also invokes scripts/update-hooks.js which rewrites hooks.py
# with the hashed bundle filename Vite emits.
if [ -f "$APP_PATH/frontend/package.json" ]; then
  log "building frappe_ai Vue frontend (Vite) — first boot installs node_modules (~1-2 min)"
  pushd "$APP_PATH/frontend" >/dev/null
  # Check for the actual vite binary, not just the directory. Reasons:
  # 1. With the named-volume mask in docker-compose.yml, node_modules is
  #    a fresh empty directory on first boot — `-d node_modules` would
  #    pass and skip the install.
  # 2. If a previous install was interrupted, .bin/vite might be missing.
  # 3. After a vite version bump, `.bin/vite` is regenerated on install.
  if [ ! -x node_modules/.bin/vite ]; then
    log "  running npm install"
    npm install --silent --no-audit --no-fund --no-progress
  fi
  log "  running vite build"
  npm run build
  popd >/dev/null
else
  log "WARNING: no frappe_ai/frontend/package.json — Vue chat UI will not be available"
fi

log "registering frappe_ai with bench"
bench get-app --skip-assets "file://$APP_PATH" || log "get-app returned non-zero (likely already registered) — continuing"

log "installing frappe_ai into site $SITE"
bench --site "$SITE" install-app frappe_ai

log "building frappe_ai assets (Frappe esbuild for public/ only)"
bench build --app frappe_ai

log "seeding AI Assistant Settings (enabled=1, agent_url=$AGENT_URL_DEFAULT)"
bench --site "$SITE" execute frappe.client.set_value \
  --kwargs "{\"doctype\": \"AI Assistant Settings\", \"name\": \"AI Assistant Settings\", \"fieldname\": {\"enabled\": 1, \"agent_url\": \"$AGENT_URL_DEFAULT\", \"timeout\": 30}}"

log "writing flag file at $FLAG_FILE"
touch "$FLAG_FILE"

log "done"
