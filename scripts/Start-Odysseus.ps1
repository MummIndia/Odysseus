# Start-Odysseus.ps1
# One-click launcher: brings up the whole Odysseus environment, in order.
#
#   1. Docker Desktop  — the compose services (odysseus, kokoro, searxng,
#                        chromadb, ntfy) are `restart: unless-stopped`, so they
#                        come back on their own once the engine is up.
#   2. Ollama          — a host app, NOT registered for autostart, so it stays
#                        down after a reboot and every model role (chat, vision)
#                        fails until it is started. This is the step that
#                        actually needs us.
#   3. compose up -d   — reconciles anything the engine did not restore.
#   4. Browser         — opened only once the app answers on its port.
#
# Safe to run when everything is already running: every step is a no-op then.

$ErrorActionPreference = 'Stop'

$ProjectDir   = 'C:\Users\Matthieu\odysseus'
$ComposeFile  = Join-Path $ProjectDir 'docker-compose.yml'
$DockerDesktop= 'C:\Program Files\Docker\Docker\Docker Desktop.exe'
$OllamaApp    = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama app.exe'
$AppUrl       = 'http://127.0.0.1:7000'
$OllamaUrl    = 'http://127.0.0.1:11434/api/version'

function Write-Step($msg) { Write-Host "  $msg" -ForegroundColor Cyan }
function Write-Ok  ($msg) { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "  [!]  $msg" -ForegroundColor Yellow }

# TCP probe. Used instead of Invoke-WebRequest because the app answers 302
# (auth redirect) and PowerShell's redirect handling makes that look like a
# connection failure.
function Test-Port([string]$ComputerName, [int]$Port) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($ComputerName, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(1000, $false)) { return $false }
        $client.EndConnect($iar)
        return $true
    } catch { return $false } finally { $client.Close() }
}

function Wait-For([scriptblock]$Check, [int]$TimeoutSec, [string]$What) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try { if (& $Check) { return $true } } catch {}
        Start-Sleep -Seconds 2
        Write-Host '.' -NoNewline -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Warn "Delai depasse en attendant $What."
    return $false
}

Write-Host ''
Write-Host '  ODYSSEUS - demarrage de l environnement' -ForegroundColor White
Write-Host '  ---------------------------------------' -ForegroundColor DarkGray

# ── 1. Docker Desktop ──
Write-Step 'Docker...'
$engineUp = $false
try { docker info *> $null; $engineUp = ($LASTEXITCODE -eq 0) } catch { $engineUp = $false }

if ($engineUp) {
    Write-Ok 'moteur Docker deja actif'
} else {
    if (-not (Test-Path $DockerDesktop)) { Write-Warn "Docker Desktop introuvable ($DockerDesktop)"; }
    else {
        Start-Process $DockerDesktop | Out-Null
        Write-Host '  demarrage de Docker Desktop (peut prendre 1-2 min)' -NoNewline -ForegroundColor DarkGray
        $null = Wait-For { docker info *> $null; $LASTEXITCODE -eq 0 } 240 'Docker'
        Write-Host ''
        try { docker info *> $null; if ($LASTEXITCODE -eq 0) { Write-Ok 'moteur Docker pret' } } catch {}
    }
}

# ── 2. Ollama (le maillon qui ne repart pas seul) ──
Write-Step 'Ollama...'
$ollamaUp = $false
try { Invoke-RestMethod -Uri $OllamaUrl -TimeoutSec 3 | Out-Null; $ollamaUp = $true } catch { $ollamaUp = $false }

if ($ollamaUp) {
    Write-Ok 'Ollama deja actif'
} elseif (Test-Path $OllamaApp) {
    Start-Process $OllamaApp | Out-Null
    Write-Host '  demarrage d Ollama' -NoNewline -ForegroundColor DarkGray
    $null = Wait-For { Invoke-RestMethod -Uri $OllamaUrl -TimeoutSec 3 | Out-Null; $true } 90 'Ollama'
    Write-Host ''
    try { Invoke-RestMethod -Uri $OllamaUrl -TimeoutSec 3 | Out-Null; Write-Ok 'Ollama pret' } catch { Write-Warn 'Ollama ne repond pas' }
} else {
    Write-Warn "Ollama introuvable ($OllamaApp)"
}

# ── 3. Services compose ──
Write-Step 'Services Odysseus (compose)...'
# No `2>&1` here: compose writes its progress lines to stderr, and PowerShell
# 5.1 turns a native command's stderr into ErrorRecords (NativeCommandError),
# which made a perfectly successful `up -d` report as a failure. Judge the run
# by its exit code instead.
docker compose -f $ComposeFile --project-directory $ProjectDir up -d | Out-Null
if ($LASTEXITCODE -eq 0) { Write-Ok 'conteneurs demarres' }
else { Write-Warn "compose up a renvoye le code $LASTEXITCODE" }

# ── 4. Attendre l app, puis ouvrir le navigateur ──
Write-Step 'Attente de l application...'
Write-Host '  ' -NoNewline
if (Wait-For { Test-Port '127.0.0.1' 7000 } 120 'Odysseus') {
    Write-Host ''
    Write-Ok "application prete sur $AppUrl"
    Start-Process $AppUrl
    Write-Host ''
    Write-Host '  Bon travail !' -ForegroundColor White
    Start-Sleep -Seconds 3
} else {
    Write-Host ''
    Write-Warn "L application ne repond pas encore sur $AppUrl"
    Write-Host '  Logs : docker logs -f odysseus-odysseus-1' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  Appuyez sur une touche pour fermer...' -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}
