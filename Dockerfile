FROM python:3.12-slim

# System deps. tmux is required by Cookbook for background downloads/serves.
# openssh-client is required for Cookbook remote server tests, setup, probes,
# downloads, and serves from Docker installs.
# git/cmake are required when Cookbook builds llama.cpp on first llama.cpp
# launch inside Docker.
# gosu lets the entrypoint drop privileges cleanly so signals still reach
# uvicorn directly (no extra shell layer like `su`/`sudo` would add).
# Node.js itself is NOT installed from apt (trixie ships Node 20); it is
# installed from the official binary below because omniroute needs Node >= 22.
# xz-utils extracts the Node .tar.xz; ca-certificates lets curl verify HTTPS.
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    curl \
    ca-certificates \
    xz-utils \
    git \
    tmux \
    openssh-client \
    gosu \
    ripgrep \
    && rm -rf /var/lib/apt/lists/*

# Node.js 22 — installed from the official binary tarball rather than Debian's
# apt package (which ships Node 20 on trixie). Provides node/npm/npx for the
# optional built-in Browser MCP server and satisfies omniroute's Node >= 22
# engine requirement. The download is checksum-verified against the signed
# SHASUMS256 manifest. Installs into /usr/local, which precedes /usr/bin on PATH.
ARG NODE_VERSION=22.23.1
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) node_arch='x64' ;; \
      arm64) node_arch='arm64' ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    f="node-v${NODE_VERSION}-linux-${node_arch}.tar.xz"; \
    curl -fsSLO "https://nodejs.org/dist/v${NODE_VERSION}/${f}"; \
    curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt" \
      | grep " ${f}\$" | sha256sum -c -; \
    tar -xJf "${f}" -C /usr/local --strip-components=1 --no-same-owner; \
    rm "${f}"; \
    node --version; npm --version

# omniroute CLI, installed globally under /usr/local/lib/node_modules.
# Requires Node >= 22 (installed above).
RUN npm install -g omniroute && omniroute --version

# Shared libraries Firefox needs to start. The built-in Playwright MCP server
# runs Firefox rather than Chromium (see src/builtin_mcp.py), and Firefox pulls
# in X11 libs — libxcb-shm, libX11-xcb, libXrandr — that the slim base lacks and
# that Chromium's dependency set does not cover. The browser build itself lives
# in the playwright-browsers volume, so only these system packages belong here.
RUN npx --yes playwright install-deps firefox \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install Python deps first (layer cache). Optional extras (PyMuPDF AGPL, etc.)
# are opt-in so the default image stays MIT-core; see requirements-optional.txt.
ARG INSTALL_OPTIONAL=false
COPY requirements.txt requirements-optional.txt ./
RUN pip install --no-cache-dir -r requirements.txt \
    && if [ "$INSTALL_OPTIONAL" = "true" ]; then pip install --no-cache-dir -r requirements-optional.txt; fi

# Local speech-to-text (microphone -> text) via faster-whisper, powering the
# "local" STT provider so prompts can be dictated without sending audio to any
# external endpoint. CPU-only by default (CTranslate2 backend, no torch needed).
# Whisper model weights download on first use into the bind-mounted HF cache
# (/app/.cache/huggingface), so they persist across container recreates.
RUN pip install --no-cache-dir faster-whisper

# Local, offline document + image tooling used by the agent and the Gallery:
#   markitdown      .docx/.pptx/.xlsx/.xls/.epub -> Markdown, for chat
#                   attachments and the personal-docs RAG index. Without it
#                   those formats are dropped entirely.
#   duckduckgo-search  proper client for the DDG search fallback instead of
#                   scraping html.duckduckgo.com.
#   rembg           background removal for /api/image/remove-bg. Runs on
#                   onnxruntime (already present via fastembed) rather than
#                   torch, so it stays CPU-friendly and light.
RUN pip install --no-cache-dir \
    "markitdown[docx,pptx,xlsx,xls]==0.1.5" \
    duckduckgo-search \
    rembg \
    opencv-python-headless

# Copy app code
COPY . .

# Create data directory (mount a volume here for persistence)
RUN mkdir -p data logs services/cache/search

# Entrypoint that drops to PUID/PGID (default 1000:1000) and repairs
# ownership on the bind-mounted /app/data and /app/logs. Without this,
# the container runs as root and writes root-owned files into host
# bind mounts — any later non-root run (or a host user trying to
# update them) silently fails on EPERM, breaking skill extraction,
# prefs persistence, mail attachments, etc.
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 7000

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "7000"]
