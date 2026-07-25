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

### `src/tool_index.py`

**Unusable browser tools were crowding out the usable ones.** Tool selection
is a semantic top-8, and `@playwright/mcp` alone exposes 30 tools. Measured
across three typical browsing requests, the agent was handed `browser_drop`,
`browser_handle_dialog`, `browser_close`, `browser_console_messages` and the
whole xy-mouse family — while **`browser_navigate` was missing in 2 cases out
of 3**. On "click the login button", 6 of the 8 slots went to mouse
primitives.

Without the tool that opens a page, every other one is dead weight. So the
model reported, accurately, that it could not reach the internet.

Two guards:

- `MCP_INDEX_DENIED` — 18 tools kept out of the index (pointer primitives,
  debugging aids, session plumbing, and `browser_run_code_unsafe`, which runs
  arbitrary JavaScript). They stay connected and callable; they just no longer
  compete for a slot.
- `MCP_COMPANIONS` — if any browser tool is retrieved, `browser_navigate` and
  `browser_snapshot` come with it. The server prefix is taken from the hit
  itself, so the rule holds under any server id.

After the fix, on the same three queries: `browser_navigate` present 3 times
out of 3, no denied tool leaking through, and every slot filled with something
useful (`navigate`, `snapshot`, `find`, `click`, `type`, `press_key`,
`select_option`). The app now indexes 12 MCP tools instead of 30.

### `src/agent_loop.py`

**Navigating is not reading.** `browser_navigate` returns the page title and a
snapshot *reference*, never the text. Measured: asked to open a URL and
summarise it, the agent called `browser_navigate`, saw `exit_code=0`, answered
"the page loaded successfully" and stopped — having read nothing. A note now
says so: navigate is never the last step, follow it with `browser_snapshot` (or
`browser_find`), and `web_fetch` does the whole job in one call when the task is
only to read.

The note also forbids `browser_snapshot`'s `filename` argument, whose own schema
reads: "Save snapshot to markdown file *instead of returning it in the
response*". The model kept inventing one and so received a file path rather than
the content — 175 characters of reference against 1634 of real content once the
argument is left out.

The note is injected only when browser tools are in that turn's selection, so it
costs nothing on unrelated requests.

### `static/js/chat.js`

**Any error containing "tool" silently disabled agent mode.** The test was
`errText.includes('tool') || errText.includes('auto')`, so any unrelated
failure — a tool timing out, an MCP server dropping, a message mentioning
"automatic" — did three things: the real error was replaced with "This model
doesn't support agent tools", the UI reverted to Chat mode, and that choice was
**written to `localStorage`**. Every later message in the conversation then ran
without tools. It presented as "agent mode works in a new chat but not in this
one".

The test now matches the provider's actual wording (Ollama: `<model> does not
support tools`), and the original error is preserved.

### `config/searxng/settings.yml`

**The default engine set returned nothing.** SearXNG queries its engines in
parallel and merges the results, so a grouped query is only as good as its
worst engine. Measured from this machine, an ordinary search returned **zero
results**: brave answered "too many requests" while duckduckgo and startpage
both served a CAPTCHA.

Queried one at a time, bing and duckduckgo return 10 results each; google,
mojeek, qwant, startpage and brave are dead or blocked. Those five are
disabled. The remaining pair returns 11-20 results consistently.

These are search engines behind a residential IP, not fixed infrastructure —
recheck if results thin out.

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

### The "web" toggle trap

The web toggle in the composer does more than allow searching: in agent mode, a
missing `allow_web_search` strips **both `web_search` and `web_fetch`**
(`routes/chat_routes.py`). With it off, the agent has no way to read a URL at
all — including one pasted straight into the message — and says so, which reads
as a refusal or a hallucination.

This is the intended behaviour: the toggle is the explicit consent to reach the
network, and leaving it off by default is the right setting for a local
install. It just has to be known that **"open this page" requires turning it on
first**. Same for the bash toggle, which alone grants `bash`.

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
