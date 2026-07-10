# Packages each driver directory into a .c4z (a plain zip with driver.xml at the root).
# Usage: pwsh tools/build.ps1  ->  outputs to dist/
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Force $dist | Out-Null

$drivers = Get-ChildItem $root -Directory | Where-Object {
    Test-Path (Join-Path $_.FullName 'driver.xml')
}
if (-not $drivers) { throw 'No driver directories (containing driver.xml) found.' }

# Never ship stray/sensitive files if one is ever left in a driver folder
# (editor backups, notes, a copied token/settings.json, VCS/OS cruft).
$excludePattern = '(\.bak$|~$|\.tmp$|\.log$|\.orig$|\.swp$|\.git|\.DS_Store$|Thumbs\.db$|settings\.json$|(\\|/)token$)'
$staging = Join-Path $dist '.staging'

foreach ($d in $drivers) {
    $out = Join-Path $dist ($d.Name + '.c4z')
    if (Test-Path $out) { Remove-Item $out -Force }

    # Stage a clean copy (preserves the www/icons/ structure), drop excluded files there.
    $stage = Join-Path $staging $d.Name
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
    New-Item -ItemType Directory -Force $stage | Out-Null
    Copy-Item -Path (Join-Path $d.FullName '*') -Destination $stage -Recurse -Force

    Get-ChildItem $stage -Recurse -Force | Where-Object { -not $_.PSIsContainer -and $_.FullName -match $excludePattern } | ForEach-Object {
        Write-Warning "Excluded from $($d.Name).c4z: $($_.FullName.Substring($stage.Length + 1))"
        Remove-Item $_.FullName -Force
    }

    # Compress the staged *contents* so driver.xml sits at the zip root.
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $out
    $count = (Get-ChildItem $stage -Recurse -File).Count
    Write-Host "Packaged $($d.Name) -> $out ($count files)"
}
if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
