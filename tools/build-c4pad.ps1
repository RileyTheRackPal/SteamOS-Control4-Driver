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
    # Reproducible, pinned build: verify the committed go.sum matches the module
    # cache, then build read-only so a stale manifest FAILS instead of being
    # silently rewritten (run `go mod tidy` deliberately, never in packaging).
    & $go mod verify
    if ($LASTEXITCODE -ne 0) { throw 'go mod verify failed (dependency hashes do not match go.sum)' }
    & $go build -mod=readonly -trimpath -ldflags '-s -w' -o (Join-Path $dist 'c4pad') .
    if ($LASTEXITCODE -ne 0) { throw 'go build failed' }
    Write-Host "Built $(Join-Path $dist 'c4pad') ($([math]::Round((Get-Item (Join-Path $dist 'c4pad')).Length / 1MB, 2)) MB)"
    Write-Host "Deploy: copy dist/c4pad + steamos-pad/{install.sh,c4pad.service} to the Steam Machine, run install.sh"
} finally {
    Remove-Item Env:GOOS, Env:GOARCH, Env:CGO_ENABLED -ErrorAction SilentlyContinue
    Pop-Location
}
