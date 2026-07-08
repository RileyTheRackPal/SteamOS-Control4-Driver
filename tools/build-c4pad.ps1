# Cross-compiles the c4pad SteamOS helper (linux/amd64 static binary) into dist/.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$src = Join-Path $root 'steamos-pad'
$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Force $dist | Out-Null

$go = "C:\Program Files\Go\bin\go.exe"
if (-not (Test-Path $go)) { $go = (Get-Command go -ErrorAction Stop).Source }

Push-Location $src
try {
    $env:GOOS = 'linux'; $env:GOARCH = 'amd64'; $env:CGO_ENABLED = '0'
    & $go mod tidy
    if ($LASTEXITCODE -ne 0) { throw 'go mod tidy failed' }
    & $go build -trimpath -ldflags '-s -w' -o (Join-Path $dist 'c4pad') .
    if ($LASTEXITCODE -ne 0) { throw 'go build failed' }
    Write-Host "Built $(Join-Path $dist 'c4pad') ($([math]::Round((Get-Item (Join-Path $dist 'c4pad')).Length / 1MB, 2)) MB)"
    Write-Host "Deploy: copy dist/c4pad + steamos-pad/{install.sh,c4pad.service} to the Steam Machine, run install.sh"
} finally {
    Remove-Item Env:GOOS, Env:GOARCH, Env:CGO_ENABLED -ErrorAction SilentlyContinue
    Pop-Location
}
