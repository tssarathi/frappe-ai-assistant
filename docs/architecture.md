# Architecture

## Containers

```
┌───────────────────── Host ─────────────────────┐
│                                                │
│   :8000 ───────►  erpnext                       │
│   :8484 ───────►  agent                         │
│                                                │
│         internal-only  mcp                      │
│         internal-only  bootstrap (init, exits)  │
│                                                │
└────────────────────────────────────────────────┘
              network: vyogo-net (bridge)
```

- `erpnext` — `docker.io/vyogo/erpnext:sne-version-15`. Serves the `frappe_ai` chat page.
- `agent` — built from `submodules/frappe-ai-agent`. Receives chat, calls LLM, calls MCP.
- `mcp` — built from `submodules/frappe-mcp-server`. Exposes ERPNext as MCP tools.
- `bootstrap` — one-shot. Installs `frappe_ai` into ERPNext on first boot, seeds `MCP Server Settings`, exits.

## Chat message flow

```
1. User types in the frappe_ai page (browser on :8000)
2. Browser → POST http://localhost:8484/api/v1/chat   (sid cookie via credentials:"include")
3. agent → LLM (per .env)
4. agent → mcp (if tool call)       ─ Cookie: sid=<sid>
5. mcp   → erpnext REST API          ─ Cookie: sid=<sid>
6. mcp   → agent (tool result)
7. agent → browser (final reply, SSE-streamed)
```

## Auth

Authentication is the Frappe `sid` cookie, end-to-end. No API keys are generated or stored. Every hop forwards the caller's sid, so the agent and MCP inherit the user's DocType permissions.

## First-boot bootstrap

`bootstrap/bootstrap.sh` is idempotent. On the very first `make up` it:

1. Waits for ERPNext to answer.
2. Auto-detects the site name from `sites/` (the image bakes `dev.localhost` and ignores `SITE_NAME`).
3. Patches `common_site_config.json` to point DB/Redis at the `erpnext` container hostname (restored on exit via `trap`).
4. Pip-installs `frappe_ai` into the bench virtualenv (`./env/bin/pip install -e apps/frappe_ai`).
5. Registers `frappe_ai` (`bench get-app`).
6. Installs it into the site (`bench install-app`).
7. Builds its frontend assets (`bench build`).
8. Seeds `MCP Server Settings`: `enabled=1`, `agent_url=http://localhost:8484`, `timeout=30`.
9. Writes `/home/frappe/frappe-bench/sites/.vyogo_bootstrapped`.

Subsequent boots see the flag and exit immediately.

## Design spec

Full design history: `docs/superpowers/specs/2026-04-23-vyogo-orchestrator-design.md` in the scratch project, if kept.
