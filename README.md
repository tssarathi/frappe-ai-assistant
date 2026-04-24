# Vyogo Stack

Docker Compose orchestrator for the Vyogo Frappe/ERPNext + AI chat stack.

This repo glues four pieces together:

1. **ERPNext** — `docker.io/vyogo/erpnext:sne-develop`.
2. **`frappe_ai`** — Frappe app providing the chat UI (git submodule).
3. **`frappe-ai-agent`** — FastAPI chat agent (git submodule).
4. **`frappe-mcp-server`** — MCP server exposing ERPNext as tools (git submodule).

A one-shot `bootstrap` container installs `frappe_ai` into ERPNext on first boot. After that the stack comes up cleanly on every subsequent `make up`.

> **Local development only.** The defaults (`ERPNEXT_ADMIN_PASSWORD=admin`, no TLS, ports bound to `0.0.0.0`) are suitable for a dev or demo machine. Do not expose this stack to the public internet.

## Quickstart

```bash
git clone --recursive https://github.com/<you>/<this-repo>.git
cd <this-repo>

cp .env.example .env
# Edit .env — either leave the default (host-local Ollama) or set your
# OpenAI / Anthropic key under one of the commented blocks.

make up
# First boot takes 3–10 minutes: ERPNext initialises, then bootstrap
# runs bench install-app + bench build for the chat frontend.
# Watch progress with:   make logs
```

Then open <http://localhost:8000> and log in as `Administrator` / `admin`, and navigate to the **frappe_ai** page.

## Common commands

| Command            | What it does                                                |
|--------------------|-------------------------------------------------------------|
| `make up`          | Build + start everything                                    |
| `make down`        | Stop containers (data preserved)                            |
| `make logs`        | Tail all logs                                               |
| `make logs SVC=agent` | Tail one service                                         |
| `make ps`          | List running containers                                     |
| `make shell`       | Bash shell in the ERPNext container (for `bench` commands)  |
| `make reset`       | Destroy data for a fresh first-boot (prompts for confirm)   |
| `make update`      | Pull newer commits on the three submodules, then rebuild    |

## Troubleshooting

- **Agent doesn't respond.** Check `make logs SVC=agent`. Most commonly the LLM is misconfigured — edit `.env`, `make up` again.
- **`frappe_ai` page 404.** Bootstrap may have failed. `make logs SVC=bootstrap`. If the flag file wasn't written, `make up` will retry automatically.
- **Change model.** Edit `LLM_MODEL` (and `LLM_BASE_URL` / `LLM_API_KEY` if switching providers) in `.env`, then `make up`.
- **Start from scratch.** `make reset`.
- **Linux without Docker Desktop.** `host.docker.internal` is mapped via the `extra_hosts: host-gateway` entry already in `docker-compose.yml` — no extra config needed. Make sure your local Ollama is listening on `0.0.0.0:11434`, not just `127.0.0.1`.

## Architecture

See [`docs/architecture.md`](docs/architecture.md).

## Submodule branch pins

The three submodules are intentionally pinned to their active integration
branches rather than each project's own `main`:

| Submodule | Pinned branch | Why |
|---|---|---|
| `frappe_ai` | `frappe-ai-agent-integration` | Active feature-integration line for the chat UI; merged back when the `frappe_ai` app cuts a release. |
| `frappe-ai-agent` | `main` | Already tracks the project's main line. |
| `frappe-mcp-server` | `feature/mcp-go-sdk` | The current MCP server implementation. This branch has been the development line since the Go rewrite; the project's `main` is a legacy Python baseline that has not been updated. Treat this pin as the source of truth until the upstream project completes its Go-migration cutover and retargets `main`. |

If you bump a pin, make sure the SHA you land on exists on the remote
(`git -C submodules/<name> push origin <branch>` before bumping the outer repo).
Rebases or force-pushes on the feature branches will orphan the outer pin.
