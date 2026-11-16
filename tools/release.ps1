<#
.SYNOPSIS
  Assemble a distributable release bundle: driver .c4z files + SteamOS helper
  binaries/installers + docs, zipped and hashed.
.DESCRIPTION
  Builds the Go helpers (c4pad, c4tls) and the template .c4z, then gathers those
  plus the already-generated game .c4z (run make-game-drivers.ps1 first) and the
  docs into dist/release/Control4-SteamMachine-<version>/ and zips it.
.EXAMPLE
  pwsh tools/release.ps1 -Version 0.1.0-beta.1
#>
param(
    [string]$Version = '0.1.0-beta.1'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$dist = Join-Path $root 'dist'
$name = "Control4-SteamMachine-$Version"
$stage = Join-Path $dist "release\$name"

Write-Host "== building release $Version =="

# 1) build the Go helpers + template .c4z (games are regenerated separately)
pwsh -NoProfile -File (Join-Path $PSScriptRoot 'build-c4pad.ps1') | Out-Null
pwsh -NoProfile -File (Join-Path $PSScriptRoot 'build-c4tls.ps1') | Out-Null
pwsh -NoProfile -File (Join-Path $PSScriptRoot 'build.ps1') | Out-Null

foreach ($f in 'c4pad', 'c4tls', "$dist\steam-machine.c4z", "$dist\steam-game-miniapp.c4z") {
    $p = if ($f -like '*.c4z') { $f } else { Join-Path $dist $f }
    if (-not (Test-Path $p)) { throw "missing build output: $p" }
}

# 2) stage the bundle
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
$dirs = @('drivers', 'drivers\games', 'steamos-helpers\steamos-pad', 'steamos-helpers\steamos-tls', 'docs')
foreach ($d in $dirs) { New-Item -ItemType Directory -Force (Join-Path $stage $d) | Out-Null }

# drivers
Copy-Item "$dist\steam-machine.c4z", "$dist\steam-game-miniapp.c4z" (Join-Path $stage 'drivers')
$games = Get-ChildItem $dist -Filter 'steam-game-*.c4z' | Where-Object { $_.BaseName -match '^steam-game-\d+$' }
if ($games) { Copy-Item $games.FullName (Join-Path $stage 'drivers\games') }
Write-Host "  drivers: 2 core + $($games.Count) games"

# SteamOS helpers (binaries + installers/units/readmes)
Copy-Item "$dist\c4pad" (Join-Path $stage 'steamos-helpers\steamos-pad')
Copy-Item "$dist\c4tls" (Join-Path $stage 'steamos-helpers\steamos-tls')
Copy-Item "$root\steamos-pad\install.sh", "$root\steamos-pad\c4pad.service", "$root\steamos-pad\README.md" (Join-Path $stage 'steamos-helpers\steamos-pad')
Copy-Item "$root\steamos-tls\install.sh", "$root\steamos-tls\c4tls.service", "$root\steamos-tls\README.md" (Join-Path $stage 'steamos-helpers\steamos-tls')

# docs
Copy-Item "$root\README.md", "$root\SECURITY.md", "$root\RELEASE_NOTES.md" $stage
Copy-Item "$root\CONTRIBUTING.md" $stage
Copy-Item "$root\docs\*.md" (Join-Path $stage 'docs')

# 3) zip + hash
$zip = Join-Path $dist "release\$name.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip
$hash = (Get-FileHash $zip -Algorithm SHA256).Hash
$sizeMB = [math]::Round((Get-Item $zip).Length / 1MB, 1)

Write-Host ""
Write-Host "== release $Version =="
Write-Host "  $zip  ($sizeMB MB)"
Write-Host "  SHA-256: $hash"
Set-Content (Join-Path $dist "release\$name.zip.sha256") "$hash  $name.zip"
