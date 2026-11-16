# Minimal dependency-free test harness (no Pester). Dot-sourced by run.ps1 into the runner scope.
#   Test 'name' { ...assertions... }              - run a test
#   Test 'name' -Skip 'reason' { ... }            - record as skipped (reason is printed)
#   Test 'BUG: ...' -Skip 'BUG: ...' { ... }      - known production bug, kept for when it is fixed
# Assertions throw on failure; Test catches and records.

$global:T = @{ Pass = 0; Fail = 0; Skip = 0; Failures = [System.Collections.Generic.List[string]]::new(); Cleanup = [System.Collections.Generic.List[string]]::new(); File = '' }

function Section([string]$Title) { Write-Host ""; Write-Host "== $Title" }

function Test {
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name,
        [Parameter(Mandatory, Position = 1)][scriptblock]$Body,
        [string]$Skip
    )
    if ($Skip) {
        $global:T.Skip++
        Write-Host "  [SKIP] $Name  ($Skip)" -ForegroundColor Yellow
        return
    }
    try {
        & $Body | Out-Null
        $global:T.Pass++
        Write-Host "  [PASS] $Name" -ForegroundColor Green
    } catch {
        $global:T.Fail++
        $msg = "$($global:T.File) :: $Name -> $($_.Exception.Message)"
        $global:T.Failures.Add($msg)
        Write-Host "  [FAIL] $Name" -ForegroundColor Red
        Write-Host "         $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Assert-True($Cond, [string]$Message = 'expected condition to be true') { if (-not $Cond) { throw $Message } }
function Assert-False($Cond, [string]$Message = 'expected condition to be false') { if ($Cond) { throw $Message } }

function Assert-Equal($Actual, $Expected, [string]$Message = '') {
    if ($Actual -is [array] -or $Expected -is [array]) {
        $a = @($Actual) -join '|'; $e = @($Expected) -join '|'
        if ($a -ne $e) { throw "expected [$e] but got [$a] $Message" }
    } elseif ($Actual -cne $Expected) {
        throw "expected [$Expected] but got [$Actual] $Message"
    }
}

function Assert-NotNull($Value, [string]$Message = 'expected a non-null value') { if ($null -eq $Value) { throw $Message } }
function Assert-Null($Value, [string]$Message = 'expected null') { if ($null -ne $Value) { throw "$Message (got [$Value])" } }
function Assert-Match([string]$Actual, [string]$Pattern, [string]$Message = '') { if ($Actual -notmatch $Pattern) { throw "expected [$Actual] to match /$Pattern/ $Message" } }
function Assert-Contains($Collection, $Item, [string]$Message = '') { if (@($Collection) -notcontains $Item) { throw "expected collection to contain [$Item] $Message" } }
function Assert-NotContains($Collection, $Item, [string]$Message = '') { if (@($Collection) -contains $Item) { throw "expected collection NOT to contain [$Item] $Message" } }
function Assert-PathExists([string]$Path) { if (-not (Test-Path -LiteralPath $Path)) { throw "path does not exist: $Path" } }
function Assert-PathMissing([string]$Path) { if (Test-Path -LiteralPath $Path) { throw "path should not exist: $Path" } }

function Assert-Throws([scriptblock]$Body, [string]$Pattern = '') {
    $threw = $false; $text = ''
    try { & $Body | Out-Null } catch { $threw = $true; $text = $_.Exception.Message }
    if (-not $threw) { throw 'expected an exception but none was thrown' }
    if ($Pattern -and $text -notmatch $Pattern) { throw "exception [$text] did not match /$Pattern/" }
}

# ---- helpers -------------------------------------------------------------
function New-TempDir([string]$Prefix = 'c4t') {
    $p = Join-Path ([System.IO.Path]::GetTempPath()) ("$Prefix-" + [guid]::NewGuid().ToString('N').Substring(0, 10))
    New-Item -ItemType Directory -Force $p | Out-Null
    $global:T.Cleanup.Add($p)
    return $p
}

function Remove-TempDirs {
    foreach ($p in $global:T.Cleanup) { if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue } }
}

function Get-RepoRoot { return $global:RepoRoot }

# Run another pwsh process. Returns @{ ExitCode; Output } (stdout+stderr merged).
function Invoke-Pwsh([string[]]$Arguments) {
    $exe = (Get-Process -Id $PID).Path
    $out = & $exe -NoProfile -NonInteractive @Arguments 2>&1 | Out-String
    return @{ ExitCode = $LASTEXITCODE; Output = $out }
}

# Entry names of a zip, normalised to forward slashes.
function Get-ZipEntries([string]$ZipPath) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try { return @($z.Entries | ForEach-Object { $_.FullName.Replace('\', '/') }) } finally { $z.Dispose() }
}

function Read-ZipText([string]$ZipPath, [string]$Entry) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $e = $z.Entries | Where-Object { $_.FullName.Replace('\', '/') -eq $Entry } | Select-Object -First 1
        if (-not $e) { throw "zip entry not found: $Entry" }
        $sr = New-Object System.IO.StreamReader($e.Open())
        try { return $sr.ReadToEnd() } finally { $sr.Dispose() }
    } finally { $z.Dispose() }
}

function Read-ZipBytes([string]$ZipPath, [string]$Entry) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $e = $z.Entries | Where-Object { $_.FullName.Replace('\', '/') -eq $Entry } | Select-Object -First 1
        if (-not $e) { throw "zip entry not found: $Entry" }
        $ms = New-Object System.IO.MemoryStream
        $s = $e.Open(); $s.CopyTo($ms); $s.Dispose()
        return , $ms.ToArray()
    } finally { $z.Dispose() }
}

# Copy the repo's tools/ + driver folders into a scratch "mini repo" so scripts that
# derive paths from $PSScriptRoot never touch the real dist/.
function New-ScratchRepo([string]$Name = 'repo', [string[]]$Dirs = @('steam-machine', 'steam-game-miniapp')) {
    $base = New-TempDir 'c4repo'
    $root = Join-Path $base $Name
    New-Item -ItemType Directory -Force $root | Out-Null
    Copy-Item -Path (Join-Path (Get-RepoRoot) 'tools') -Destination $root -Recurse -Force
    foreach ($d in $Dirs) { Copy-Item -Path (Join-Path (Get-RepoRoot) $d) -Destination $root -Recurse -Force }
    return $root
}
