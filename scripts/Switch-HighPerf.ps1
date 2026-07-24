# Switch-HighPerf.ps1
# Run this AFTER the charging port is repaired.
#
# While the port is faulty the machine sits on a survival power budget: the
# battery neither charges nor discharges and the RTX 4090 stays pinned to
# P-state P8 (210 MHz of 3105, ~19 W), which is roughly a 10x slowdown. Under
# that clamp a 14B model manages ~1.7 tok/s, so Odysseus was configured around
# small models instead.
#
# This script verifies the GPU can actually boost again, and only then promotes
# qwen3:14b (already downloaded) to the default chat + research model.

$ErrorActionPreference = 'Stop'

$Settings = 'C:\Users\Matthieu\odysseus\data\settings.json'
$BigModel = 'qwen3:14b'
$MinClockMHz = 1000   # P8 idle sits at 210; a healthy boost clears 1500+

function Write-Ok  ($m) { Write-Host "  [OK] $m" -ForegroundColor Green }
function Write-Warn($m) { Write-Host "  [!]  $m" -ForegroundColor Yellow }

Write-Host ''
Write-Host '  Odysseus - bascule haute performance' -ForegroundColor White
Write-Host '  -----------------------------------' -ForegroundColor DarkGray

# ── 1. Charging state ──
$bat = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
if ($bat) { Write-Host "  Batterie : $($bat.EstimatedChargeRemaining)%" -ForegroundColor DarkGray }

# ── 2. Does the GPU actually boost? ──
# Idle clocks are always low, so load the GPU briefly and sample under load.
Write-Host '  Test de monte en frequence du GPU...' -ForegroundColor Cyan
$job = Start-Job {
    try {
        Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/generate' -Method Post `
            -ContentType 'application/json' -TimeoutSec 120 `
            -Body '{"model":"qwen3:4b","prompt":"Compte de 1 a 50.","stream":false,"think":false}'
    } catch {}
}
Start-Sleep -Seconds 10
$peak = 0
for ($i = 0; $i -lt 6; $i++) {
    $c = (& nvidia-smi --query-gpu=clocks.sm --format=csv,noheader,nounits) 2>$null
    if ($c -match '^\d+$' -and [int]$c -gt $peak) { $peak = [int]$c }
    Start-Sleep -Seconds 2
}
Remove-Job $job -Force -ErrorAction SilentlyContinue

Write-Host "  Frequence GPU max observee : $peak MHz" -ForegroundColor DarkGray

if ($peak -lt $MinClockMHz) {
    Write-Warn "Le GPU plafonne a $peak MHz — il est toujours bride."
    Write-Host '  La reparation n a pas leve la limitation, ou la batterie est encore trop basse.' -ForegroundColor DarkGray
    Write-Host '  Configuration inchangee (petits modeles conserves).' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  Appuyez sur une touche pour fermer...' -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    exit 1
}

Write-Ok "GPU debride ($peak MHz)"

# ── 3. Promote the big model ──
$json = Get-Content $Settings -Raw | ConvertFrom-Json
$json.default_model  = $BigModel
$json.research_model = $BigModel
$json | ConvertTo-Json -Depth 20 | Set-Content $Settings -Encoding utf8
Write-Ok "Modele principal + recherche -> $BigModel"
Write-Host '  (utilitaire/taches restent sur llama3.2 : les titres et resumes gagnent a etre instantanes)' -ForegroundColor DarkGray

# Settings are re-read from disk within ~2s (TTL cache), no restart needed.
Write-Host ''
Write-Ok 'Termine. Rechargez la page Odysseus.'
Start-Sleep -Seconds 4
