# Cross-compiles the c4tls TLS proxy (linux/amd64 static binary) into dist/.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$src = Join-Path $root 'steamos-tls'
$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Force $dist | Out-Null

$go = "C:\Program Files\Go\bin\go.exe"
if (-not (Test-Path $go)) { $go = (Get-Command go -ErrorAction Stop).Source }

Push-Location $src
try {
    $env:GOOS = 'linux'; $env:GOARCH = 'amd64'; $env:CGO_ENABLED = '0'
    # stdlib-only: go.sum is empty, so mod verify is a no-op but confirms no deps crept in
    & $go mod verify
    if ($LASTEXITCODE -ne 0) { throw 'go mod verify failed' }
    & $go build -mod=readonly -trimpath -ldflags '-s -w' -o (Join-Path $dist 'c4tls') .
    if ($LASTEXITCODE -ne 0) { throw 'go build failed' }
    Write-Host "Built $(Join-Path $dist 'c4tls') ($([math]::Round((Get-Item (Join-Path $dist 'c4tls')).Length / 1MB, 2)) MB)"
} finally {
    Remove-Item Env:GOOS, Env:GOARCH, Env:CGO_ENABLED -ErrorAction SilentlyContinue
    Pop-Location
}
