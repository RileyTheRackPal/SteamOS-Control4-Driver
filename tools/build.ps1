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

foreach ($d in $drivers) {
    $out = Join-Path $dist ($d.Name + '.c4z')
    if (Test-Path $out) { Remove-Item $out -Force }
    # Compress the *contents* of the driver dir so driver.xml sits at the zip root.
    Compress-Archive -Path (Join-Path $d.FullName '*') -DestinationPath $out
    Write-Host "Packaged $($d.Name) -> $out"
}
