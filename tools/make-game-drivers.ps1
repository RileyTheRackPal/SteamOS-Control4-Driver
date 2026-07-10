<#
.SYNOPSIS
  Batch-generate Steam game mini-drivers for the top-50 most-played games and/or all
  Valve titles, each as a per-game .c4z with the square icon baked in.
.DESCRIPTION
  -Top50  : the current top-50 most-played games (Steam charts API, keyless)
  -Valve  : all Valve game titles (curated, live-verified AppID list)
  -AppIds : an explicit comma list of AppIDs
  With no switch, builds both Top50 + Valve. AppIDs are de-duplicated across sets.
.EXAMPLE
  pwsh tools/make-game-drivers.ps1              # top50 + all Valve titles
  pwsh tools/make-game-drivers.ps1 -Valve       # just Valve titles
  pwsh tools/make-game-drivers.ps1 -Top50 -Style icon
#>
param(
    [switch]$Top50,
    [switch]$Valve,
    [int[]]$AppIds,
    [ValidateSet('auto', 'icon', 'logo', 'boxart')][string]$Style = 'auto',
    [int]$DelayMs = 350
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/steam-driver-lib.ps1"
$root = Split-Path $PSScriptRoot -Parent

# Valve games - live-verified AppIDs (type=game), SDKs/tools/soundtracks excluded.
$ValveGames = @(
    10, 20, 30, 40, 50, 60, 70, 80, 130, 220, 240, 280, 300, 320, 340, 360, 380,
    400, 420, 440, 500, 550, 570, 620, 630, 730, 450390, 546560, 583950, 1046930,
    1269260, 1422450, 1902490
)

function Get-Top50AppIds {
    try {
        $r = Invoke-RestMethod -Uri 'https://api.steampowered.com/ISteamChartsService/GetMostPlayedGames/v1/' -TimeoutSec 25
        return @($r.response.ranks | Sort-Object rank | Select-Object -First 50 | ForEach-Object { [int]$_.appid })
    } catch {
        Write-Warning "Could not fetch the most-played chart: $($_.Exception.Message)"
        return @()
    }
}

# Resolve which sets to build (default = both)
$doTop = $Top50 -or (-not $Top50 -and -not $Valve -and -not $AppIds)
$doValve = $Valve -or (-not $Top50 -and -not $Valve -and -not $AppIds)

$targets = [System.Collections.Generic.List[int]]::new()
$seen = [System.Collections.Generic.HashSet[int]]::new()
function Add-Targets($ids) { foreach ($id in $ids) { if ($seen.Add([int]$id)) { $targets.Add([int]$id) } } }

if ($AppIds) { Add-Targets $AppIds }
if ($doTop) {
    $top = Get-Top50AppIds
    Write-Host "Top-50 most-played: $($top.Count) AppIDs"
    Add-Targets $top
}
if ($doValve) {
    Write-Host "Valve titles: $($ValveGames.Count) AppIDs"
    Add-Targets $ValveGames
}

Write-Host "Building $($targets.Count) unique game drivers (style=$Style)..."
Write-Host ""

$ok = 0; $fail = @(); $bySource = @{}
foreach ($appid in $targets) {
    try {
        $name = Get-SteamGameName ([string]$appid)
        $src = New-SteamGameDriver -AppId ([string]$appid) -Name $name -Style $Style -Root $root
        $bySource[$src] = ([int]$bySource[$src]) + 1
        $ok++
        Write-Host ("  [{0,3}/{1}] {2,-40} appid {3,-8} icon:{4}" -f $ok, $targets.Count, $name, $appid, $src)
    } catch {
        $fail += $appid
        Write-Warning ("  appid {0}: {1}" -f $appid, $_.Exception.Message)
    }
    Start-Sleep -Milliseconds $DelayMs  # be polite to the Steam APIs
}

Write-Host ""
Write-Host "Done: $ok built, $($fail.Count) failed. Icon sources: $(($bySource.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ')"
if ($fail.Count) { Write-Host "Failed AppIDs: $($fail -join ', ')" }
Write-Host "Output: dist/steam-game-<appid>.c4z"
