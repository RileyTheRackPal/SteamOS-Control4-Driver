# Runner: pwsh -NoProfile -File tests/powershell/run.ps1 [-Filter <substring of test-file name>]
# Discovers tests/powershell/*.Tests.ps1, runs them, prints a summary, exits non-zero on any failure.
param([string]$Filter = '')
$ErrorActionPreference = 'Stop'
$global:TestDir = $PSScriptRoot
$global:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $PSScriptRoot 'TestHarness.ps1')

$files = Get-ChildItem -Path $PSScriptRoot -Filter '*.Tests.ps1' | Sort-Object Name | Where-Object { $_.Name -like "*$Filter*" }
if (-not $files) { Write-Host "No test files found."; exit 1 }

Write-Host "PowerShell $($PSVersionTable.PSVersion) on $([System.Runtime.InteropServices.RuntimeInformation]::OSDescription)"
try {
    foreach ($f in $files) {
        $global:T.File = $f.Name
        Write-Host ""
        Write-Host "##### $($f.Name)"
        try { . $f.FullName }
        catch {
            $global:T.Fail++
            $global:T.Failures.Add("$($f.Name) :: file-level error -> $($_.Exception.Message)")
            Write-Host "  [FAIL] (file-level error) $($_.Exception.Message)" -ForegroundColor Red
        }
    }
} finally {
    Set-Location $global:RepoRoot
    Remove-TempDirs
}

$t = $global:T
Write-Host ""
Write-Host "=================================================="
Write-Host ("Total: {0}  Passed: {1}  Skipped: {2}  Failed: {3}" -f ($t.Pass + $t.Skip + $t.Fail), $t.Pass, $t.Skip, $t.Fail)
if ($t.Fail -gt 0) {
    Write-Host "Failures:" -ForegroundColor Red
    $t.Failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
exit 0
