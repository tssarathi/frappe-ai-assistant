# Vyogo Stack

Docker Compose orchestrator for the Vyogo Frappe/ERPNext + AI chat stack.

This repo glues four pieces together:

1. **ERPNext** — `docker.io/vyogo/erpnext:sne-version-15`.
2. **`frappe_ai`** — Frappe app providing the chat UI (git submodule).
3. **`frappe-ai-agent`** — FastAPI chat agent (git submodule).
4. **`frappe-mcp-server`** — MCP server exposing ERPNext as tools (git submodule).

A one-shot `bootstrap` container installs `frappe_ai` into ERPNext on first boot. After that the stack comes up cleanly on every subsequent `make up`.

## Quickstart

```bash
git clone --recursive https://github.com/<you>/<this-repo>.git
cd <this-repo>

cp .env.example .env
# Edit .env — either leave the default (host-local Ollama) or set your
# OpenAI / Anthropic key under one of the commented blocks.

make up
# First boot takes ~2 minutes while ERPNext initialises, then bootstrap
# installs frappe_ai. Watch with:   make logs
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

## Architecture

See [`docs/architecture.md`](docs/architecture.md).
