<#
.SYNOPSIS
  Run every test suite in the repo: Lua driver specs, PowerShell build-tool tests,
  and the Go helper tests (c4pad, c4tls).
.DESCRIPTION
  The Go helpers are Linux-only (//go:build linux). On Linux they run with
  `go test`. On Windows they are vetted and compiled as static linux/amd64 test
  binaries, then executed inside a WSL distro (default: docker-desktop) if one is
  available; otherwise only the compile check runs and the suite is reported as
  "compiled, not run".
.EXAMPLE
  pwsh tools/test.ps1
  pwsh tools/test.ps1 -Suite lua,go
  pwsh tools/test.ps1 -WslDistro Ubuntu
#>
param(
    [ValidateSet('lua', 'powershell', 'go')]
    [string[]]$Suite = @('lua', 'powershell', 'go'),
    [string]$WslDistro = 'docker-desktop'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$results = [ordered]@{}

function Invoke-Step([string]$Name, [scriptblock]$Body) {
    Write-Host ""
    Write-Host "==== $Name ====" -ForegroundColor Cyan
    try {
        $script:status = $null
        & $Body | Out-Host
        $results[$Name] = if ($script:status) { $script:status } else { 'PASS' }
    } catch {
        Write-Host $_ -ForegroundColor Red
        $results[$Name] = 'FAIL'
    }
}

function Find-Lua {
    foreach ($c in 'lua5.4', 'lua54', 'lua') {
        $cmd = Get-Command $c -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    return $null
}

Push-Location $root
try {
    if ('lua' -in $Suite) {
        Invoke-Step 'lua' {
            $lua = Find-Lua
            if (-not $lua) { Write-Host 'lua not found on PATH'; $script:status = 'SKIP (no lua)'; return }
            & $lua (Join-Path 'tests' 'lua' 'run.lua')
            if ($LASTEXITCODE -ne 0) { throw "lua suite exited $LASTEXITCODE" }
        }
    }

    if ('powershell' -in $Suite) {
        Invoke-Step 'powershell' {
            pwsh -NoProfile -File (Join-Path 'tests' 'powershell' 'run.ps1')
            if ($LASTEXITCODE -ne 0) { throw "powershell suite exited $LASTEXITCODE" }
        }
    }

    if ('go' -in $Suite) {
        foreach ($m in 'steamos-pad', 'steamos-tls') {
            Invoke-Step "go:$m" {
                if (-not (Get-Command go -ErrorAction SilentlyContinue)) { $script:status = 'SKIP (no go)'; return }
                Push-Location (Join-Path $root $m)
                try {
                    if ($IsLinux) {
                        go vet ./...
                        if ($LASTEXITCODE -ne 0) { throw 'go vet failed' }
                        go test -count=1 ./...
                        if ($LASTEXITCODE -ne 0) { throw 'go test failed' }
                        return
                    }

                    # cross-compile a static linux test binary
                    $saved = @{ GOOS = $env:GOOS; GOARCH = $env:GOARCH; CGO_ENABLED = $env:CGO_ENABLED }
                    $bin = Join-Path ([IO.Path]::GetTempPath()) "$m.test"
                    try {
                        $env:GOOS = 'linux'; $env:GOARCH = 'amd64'; $env:CGO_ENABLED = '0'
                        go vet ./...
                        if ($LASTEXITCODE -ne 0) { throw 'go vet failed' }
                        go test -c -o $bin
                        if ($LASTEXITCODE -ne 0) { throw 'go test -c failed' }
                    } finally {
                        foreach ($k in $saved.Keys) { Set-Item "env:$k" $saved[$k] -ErrorAction SilentlyContinue; if ($null -eq $saved[$k]) { Remove-Item "env:$k" -ErrorAction SilentlyContinue } }
                    }

                    $haveWsl = $IsWindows -and (Get-Command wsl.exe -ErrorAction SilentlyContinue) -and
                        (((wsl.exe -l -q) -join "`n") -replace "`0", '' -split "`r?`n" | Where-Object { $_.Trim() -eq $WslDistro })
                    if (-not $haveWsl) {
                        Write-Host "WSL distro '$WslDistro' not found - compiled only, not run"
                        $script:status = 'COMPILED (not run)'; return
                    }
                    # Windows drive C: is mounted at /mnt/host/c in docker-desktop, /mnt/c in normal distros
                    $drive = $bin.Substring(0, 1).ToLower()
                    $rest = $bin.Substring(2) -replace '\\', '/'
                    $sh = "for p in /mnt/host/$drive$rest /mnt/$drive$rest; do [ -f `"`$p`" ] && cp `"`$p`" /tmp/$m.test && break; done; chmod +x /tmp/$m.test && cd /tmp && /tmp/$m.test -test.count=1"
                    wsl.exe -d $WslDistro -e sh -c $sh
                    if ($LASTEXITCODE -ne 0) { throw "$m tests failed (exit $LASTEXITCODE)" }
                } finally {
                    Pop-Location
                }
            }
        }
    }
} finally {
    Pop-Location
}

Write-Host ""
Write-Host "==== summary ====" -ForegroundColor Cyan
$failed = $false
foreach ($k in $results.Keys) {
    $v = $results[$k]
    $color = if ($v -eq 'FAIL') { $failed = $true; 'Red' } elseif ($v -eq 'PASS') { 'Green' } else { 'Yellow' }
    Write-Host ("  {0,-18} {1}" -f $k, $v) -ForegroundColor $color
}
if ($failed) { exit 1 }
