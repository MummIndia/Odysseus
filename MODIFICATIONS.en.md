*[Français](MODIFICATIONS.md) · **English***

# What this fork changes

This repository is a copy of [pewdiepie-archdaemon/odysseus](https://github.com/pewdiepie-archdaemon/odysseus)
adapted for a **fully local Windows + Docker** deployment. No cloud service, no
API key: every capability runs against an open-source engine on the machine.

Upstream is already built for this — these changes mostly close the gaps that,
in practice, left features silently inactive on that environment.

---

## At a glance

| Capability | Engine |
|---|---|
| Chat, tasks, research | Ollama (local models) |
| Vision | `qwen2.5vl` via Ollama |
| Speech-to-text | faster-whisper, on-device |
| Text-to-speech | Kokoro, in its own container |
| Agent web browsing | Playwright + **Firefox** |
| Web search | self-hosted SearXNG, DuckDuckGo fallback |
| Embeddings / RAG | fastembed (ONNX) + ChromaDB |
| Notifications | self-hosted ntfy |

---

## The changes

### `Dockerfile`

**Node.js 22 instead of the Debian package.** The base image ships Node 20,
below what some npm tooling requires. The official tarball is installed into
`/usr/local` (which precedes `/usr/bin` on PATH) after verifying its SHA-256
against the signed manifest. The Debian package stays: many `node-*` packages
depend on it.

**Optional dependencies baked into the image.** Upstream leaves these optional,
and their absence is silent — the feature simply never responds. Now included:

| Package | Without it |
|---|---|
| `faster-whisper` | dictation is configured but transcribes nothing |
| `markitdown` | `.docx` / `.xlsx` / `.pptx` are skipped by chat **and** by the RAG index |
| `duckduckgo-search` | the search fallback degrades to HTML scraping |
| `rembg` | no background removal in the Gallery |
| `ripgrep` | the agent's `grep` tool uses a slower implementation |

**Firefox's X11 libraries.** The browser MCP server runs Firefox (see below),
which needs `libxcb-shm`, `libX11-xcb` and `libXrandr` — absent from the slim
image and not covered by Chromium's dependency set.

> ⚠️ Any `pip install` or `apt install` done inside a running container is lost
> the first time it is recreated. Only the `Dockerfile` persists.

### `docker-compose.yml`

**`kokoro` service** — local neural text-to-speech exposing an OpenAI-compatible
`/v1/audio/speech`. Read-aloud therefore stays offline, with no key or account.

**`HOME=/app`** — fixes an inconsistency. The entrypoint drops privileges with
`gosu`, which *preserves the environment*, so `HOME` stayed at `/root` —
unreadable for uid 1000. Everything else already assumed `/app` (the entrypoint
puts `pip install --user` output there). The concrete symptom: npx could not
find its cache, which disabled the browser MCP server.

**Named volumes for the npx cache and Playwright browsers.** These caches can
live neither:

- in the container layer — wiped on every recreate; nor
- on a Windows bind mount — reading the `node_modules` tree there takes roughly
  ten seconds, far past the cache probe's timeout.

A Docker volume (stored Linux-side) satisfies both constraints.

### `src/builtin_mcp.py`

**Firefox instead of Chromium** (`--browser firefox`). Playwright defaults to
Chromium; Firefox is preferred here as the fully open-source, Mozilla-backed
engine. Other accepted values are `chrome`, `webkit` and `msedge`.

**Environment passed to MCP servers.** `_connect_stdio` built
`env={**os.environ, **env} if env else None`. `None` does not mean "inherit" —
the MCP SDK substitutes a minimal default environment. The Python servers pass
`PYTHONPATH`, so they inherited everything; the NPX server passed nothing and
lost `PLAYWRIGHT_BROWSERS_PATH`. It then looked for browsers in the default
cache and reported `Browser "firefox" is not installed`, with the browser sitting
installed one directory away.

**Reconnecting built-in MCP servers.** A session can vanish without the process
dying (a stdio teardown racing across asyncio tasks). The existing recovery only
ran when a call raised, which presupposes a session, so a missing session was
terminal. It is now attempted in that case too, and covers the NPX servers — the
browser was excluded by a membership test against the Python-server dict alone.

> ⚠️ Browsers must be installed with the Playwright version bundled inside
> `@playwright/mcp`, not with the standalone `playwright` package: the build
> numbers differ and the server rejects the one it did not expect.
> `npx @playwright/mcp@latest install-browser firefox`, as uid 1000. They live in
> the `playwright-browsers` volume, so outside the image.

**npx cache probe timeout raised from 5s to 25s.** The probe fires during
startup, while the app is also loading FastEmbed, reaching ChromaDB and
spawning the other MCP servers. A hit in an already-populated cache costs ~1s
on an idle machine, but drifted past 5s under that load — the browser server
was then dropped as "not installed" while the cache was perfectly fine. A
genuine cache miss still returns immediately, so the larger ceiling costs
nothing in the real failure case.

### `static/`

Read-aloud (`TTS Mode`) was hidden in the UI. It is re-enabled and **on by
default**, toggleable from the **+** menu in the composer.

### `scripts/`

| Script | Purpose |
|---|---|
| `Start-Odysseus.ps1` | Brings the environment up in order: Docker, then Ollama, then the services; waits for the app to answer and opens it. A no-op when everything is already running. |
| `Switch-HighPerf.ps1` | Promotes the chat model to a larger one, **only** after confirming the GPU actually boosts under load. |
| `odysseus.ico` | Shortcut icon, derived from the project favicon. |

`Start-Odysseus.ps1` exists because Ollama runs on the host, not in Docker: the
containers restart themselves (`restart: unless-stopped`), Ollama does not.

---

## Configuration outside the repository

Settings live in `data/`, **excluded by `.gitignore`** — it holds accounts,
conversations and encryption keys. After a clone you therefore reconfigure
through the UI: per-role models (chat, utility, tasks, research, vision), the
STT/TTS providers, and the Ollama endpoint.

The models themselves come from `ollama pull`.

### The settings that actually mattered

On modest hardware these four did more than the choice of model:

| Setting | Value | Why |
|---|---|---|
| `disabled_tools` | keep 13 tools | A small model picks badly among 29 options — it looped on `api_call`/`app_api`. Keep what it needs to code and act (`bash`, `python`, `ls`, `glob`, `grep`, `read_file`, `write_file`, `edit_file`, `web_search`, `web_fetch`, `manage_memory`, `ask_user`, `update_plan`) and drop the rest. |
| One model across roles | chat = utility = tasks | A distinct model per role keeps several resident in VRAM at once. |
| `OLLAMA_CONTEXT_LENGTH` | 8192 | The compact system prompt plus the tool schemas come to ~4,200 tokens: under the 4096 default Ollama truncates, and the model then claims it does not have the tools it was just handed. Size it on the measured need — the surplus is paid for in memory. |
| `OLLAMA_KEEP_ALIVE` | `-1` | Avoids reloading several GB after five idle minutes. Only combine with a large context while watching VRAM. |

⚠️ On Windows, restarting Ollama means killing **`llama-server`** as well as
`ollama`: the models are held by those child processes, and an `ollama*` filter
leaves them orphaned with their allocation. Each incomplete restart then leaks a
full model's worth of VRAM until generations get cut mid-stream (`peer closed
connection`, surfacing as a 502). Comparing `ollama ps` against `nvidia-smi`
exposes the gap.

---

## Tracking upstream

Two edits touch an upstream file and will be overwritten by
`git pull origin dev`:

- `src/builtin_mcp.py` — the `--browser firefox` argument
- `src/builtin_mcp.py` — the npx probe timeout (5s → 25s)

Without them the browser MCP server stops loading. The corresponding commit
message spells both out, which is how to find and re-apply them after a merge.

---

## Licence

Upstream is MIT-licensed and that licence is preserved as-is
(see [`LICENSE`](LICENSE) and [`ACKNOWLEDGMENTS.md`](ACKNOWLEDGMENTS.md)).
