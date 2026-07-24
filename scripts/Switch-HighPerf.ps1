# Switch-HighPerf.ps1
# Promotes the larger chat model - but only once the GPU is confirmed to boost.
#
# A laptop GPU can sit pinned in a low-power state (P8, a few hundred MHz
# instead of a few thousand) whenever the system is on a constrained power
# budget: battery saver, an underpowered or faulty adapter, a vendor thermal
# profile. Utilisation still reads ~100%, so the only reliable signal is the
# clock under load. Inference then runs roughly an order of magnitude slower,
# and a model that is excellent on a healthy machine becomes unusable.
#
# Rather than assume, this script loads the GPU briefly, samples the clock, and
# only switches the configuration if the card actually boosts. Otherwise it
# leaves the small-model setup alone and says so.
#
# Paths are derived from this script's own location, so the repository can live
# anywhere.

$ErrorActionPreference = 'Stop'

$ProjectDir  = Split-Path -Parent $PSScriptRoot
$Settings    = Join-Path $ProjectDir 'data\settings.json'
$BigModel    = 'qwen3:14b'   # promoted when the GPU is healthy
$ProbeModel  = 'qwen3:4b'    # small model used to put the GPU under load
$MinClockMHz = 1000          # a throttled card idles near 200; a healthy one clears 1500+

function Write-Ok  ($m) { Write-Host "  [OK] $m" -ForegroundColor Green }
function Write-Warn($m) { Write-Host "  [!]  $m" -ForegroundColor Yellow }

Write-Host ''
Write-Host '  Odysseus - bascule haute performance' -ForegroundColor White
Write-Host '  -----------------------------------' -ForegroundColor DarkGray

if (-not (Test-Path $Settings)) {
    Write-Warn "Fichier de reglages introuvable ($Settings)"
    exit 1
}

# -- Does the GPU actually boost? --
# Idle clocks are always low, so load the GPU first and sample under load.
Write-Host '  Test de montee en frequence du GPU...' -ForegroundColor Cyan
$job = Start-Job -ArgumentList $ProbeModel {
    param($model)
    try {
        $body = @{ model = $model; prompt = 'Compte de 1 a 50.'; stream = $false; think = $false } | ConvertTo-Json
        Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/generate' -Method Post `
            -ContentType 'application/json' -TimeoutSec 120 -Body $body
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

if ($peak -eq 0) {
    Write-Warn 'Aucune mesure GPU (nvidia-smi indisponible ?) - configuration inchangee.'
    exit 1
}

Write-Host "  Frequence GPU max observee : $peak MHz" -ForegroundColor DarkGray

if ($peak -lt $MinClockMHz) {
    Write-Warn "Le GPU plafonne a $peak MHz - il est toujours bride."
    Write-Host '  Verifiez l alimentation et le profil energetique du systeme.' -ForegroundColor DarkGray
    Write-Host '  Configuration inchangee (petits modeles conserves).' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  Appuyez sur une touche pour fermer...' -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    exit 1
}

Write-Ok "GPU debride ($peak MHz)"

# -- Promote the big model --
$json = Get-Content $Settings -Raw | ConvertFrom-Json
$json.default_model  = $BigModel
$json.research_model = $BigModel
$json | ConvertTo-Json -Depth 20 | Set-Content $Settings -Encoding utf8
Write-Ok "Modele principal + recherche -> $BigModel"
Write-Host '  (utilitaire/taches restent sur un petit modele : titres et resumes gagnent a etre instantanes)' -ForegroundColor DarkGray

# Settings are re-read from disk within ~2s (TTL cache), no restart needed.
Write-Host ''
Write-Ok 'Termine. Rechargez la page Odysseus.'
Start-Sleep -Seconds 4
