# Tests for the remaining tools/*.ps1 entry points. Anything needing the network or Go is either
# exercised through stubs (release.ps1 with stub helper builds), through AST extraction of the
# pure parts (make-game-drivers.ps1), or checked statically (build-c4pad/build-c4tls).

$toolsDir = Join-Path (Get-RepoRoot) 'tools'
$isWin = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)
$winOnly = if ($isWin) { $null } else { 'Windows-only script (backslash paths / System.Drawing)' }

function Get-ScriptAst([string]$Path) {
    $errs = $null; $tok = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tok, [ref]$errs)
    return @{ Ast = $ast; Errors = $errs }
}

# ---------------------------------------------------------------- syntax
Section 'all tools/*.ps1: syntax'
foreach ($f in Get-ChildItem $toolsDir -Filter *.ps1) {
    $path = $f.FullName; $nm = $f.Name
    Test "$nm parses without syntax errors" {
        $r = Get-ScriptAst $path
        Assert-Equal @($r.Errors).Count 0 (($r.Errors | ForEach-Object Message) -join '; ')
    }
}

# ---------------------------------------------------------------- make-game-driver.ps1 / make-game-drivers.ps1 input validation
Section 'make-game-driver(s).ps1: parameter validation (fails at binding, before any network call)'

Test 'make-game-driver: non-numeric AppId is rejected' {
    foreach ($bad in 'abc', '620; calc', '..\x', '-1', '6 2') {
        $r = Invoke-Pwsh @('-File', (Join-Path $toolsDir 'make-game-driver.ps1'), '-AppId', $bad)
        Assert-True ($r.ExitCode -ne 0) "AppId '$bad' was accepted"
        Assert-Match $r.Output 'AppId|pattern'
    }
}
Test 'make-game-driver: AppId is mandatory (non-interactive run fails)' {
    $r = Invoke-Pwsh @('-File', (Join-Path $toolsDir 'make-game-driver.ps1'))
    Assert-True ($r.ExitCode -ne 0)
}
Test 'make-game-driver: invalid -Style is rejected' {
    $r = Invoke-Pwsh @('-File', (Join-Path $toolsDir 'make-game-driver.ps1'), '-AppId', '620', '-Style', 'neon')
    Assert-True ($r.ExitCode -ne 0)
    Assert-Match $r.Output 'Style|neon'
}
Test 'make-game-driver: declared Style set is auto/icon/logo/boxart and AppId pattern is ^\d+$' {
    $ast = (Get-ScriptAst (Join-Path $toolsDir 'make-game-driver.ps1')).Ast
    $params = @{}; foreach ($p in $ast.ParamBlock.Parameters) { $params[$p.Name.VariablePath.UserPath] = $p }
    $style = @($params['Style'].Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' } | ForEach-Object { $_.PositionalArguments | ForEach-Object { $_.Value } })
    Assert-Equal $style @('auto', 'icon', 'logo', 'boxart')
    $pat = @($params['AppId'].Attributes | Where-Object { $_.TypeName.Name -eq 'ValidatePattern' })[0].PositionalArguments[0].Value
    Assert-Equal $pat '^\d+$'
    Assert-True ('620' -match $pat); Assert-False ('62a' -match $pat)
}
Test 'make-game-drivers: non-integer -AppIds and invalid -Style are rejected' {
    $r = Invoke-Pwsh @('-File', (Join-Path $toolsDir 'make-game-drivers.ps1'), '-AppIds', 'abc')
    Assert-True ($r.ExitCode -ne 0)
    $r = Invoke-Pwsh @('-File', (Join-Path $toolsDir 'make-game-drivers.ps1'), '-AppIds', '620', '-Style', 'neon')
    Assert-True ($r.ExitCode -ne 0)
}

Section 'make-game-drivers.ps1: pure parts via AST extraction'
$mgdAst = (Get-ScriptAst (Join-Path $toolsDir 'make-game-drivers.ps1')).Ast

Test 'curated Valve AppID list is non-empty, positive, unique ints' {
    $assign = $mgdAst.Find({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$ValveGames' }, $true)
    Assert-NotNull $assign 'ValveGames assignment not found'
    $ids = @(& ([scriptblock]::Create($assign.Right.Extent.Text)))
    Assert-True ($ids.Count -ge 20) "only $($ids.Count) ids"
    foreach ($i in $ids) { Assert-True ($i -is [int] -and $i -gt 0) "bad id $i" }
    $dupes = @($ids | Group-Object | Where-Object Count -gt 1 | ForEach-Object Name)
    Assert-Equal $dupes.Count 0 "duplicates: $($dupes -join ',')"
    Assert-Contains $ids 620; Assert-Contains $ids 730; Assert-Contains $ids 440
}
Test 'Add-Targets de-duplicates across sets and preserves first-seen order' {
    $fn = $mgdAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Add-Targets' }, $true)
    Assert-NotNull $fn
    $targets = [System.Collections.Generic.List[int]]::new()
    $seen = [System.Collections.Generic.HashSet[int]]::new()
    . ([scriptblock]::Create($fn.Extent.Text))
    Add-Targets @(5, 3, 5)
    Add-Targets @('3', 9, 5, 1)
    Assert-Equal @($targets) @(5, 3, 9, 1)
}
Test 'Get-Top50AppIds returns the 50 best ranks as ints, sorted by rank (stubbed API)' {
    $fn = $mgdAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-Top50AppIds' }, $true)
    Assert-NotNull $fn
    . ([scriptblock]::Create($fn.Extent.Text))
    function Invoke-RestMethod { param($Uri, $TimeoutSec) [pscustomobject]@{ response = [pscustomobject]@{ ranks = @(60..1 | ForEach-Object { [pscustomobject]@{ rank = $_; appid = 1000 + $_ } }) } } }
    try {
        $ids = @(Get-Top50AppIds)
        Assert-Equal $ids.Count 50
        Assert-Equal $ids[0] 1001
        Assert-Equal $ids[49] 1050
        Assert-True ($ids[0] -is [int])
    } finally { Remove-Item function:Invoke-RestMethod }
}
Test 'Get-Top50AppIds returns an empty list (with a warning) when the API fails' {
    $fn = $mgdAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-Top50AppIds' }, $true)
    . ([scriptblock]::Create($fn.Extent.Text))
    function Invoke-RestMethod { param($Uri, $TimeoutSec) throw 'offline' }
    try {
        $ids = @(Get-Top50AppIds -WarningAction SilentlyContinue)
        Assert-Equal $ids.Count 0
    } finally { Remove-Item function:Invoke-RestMethod }
}
Test 'make-game-drivers end-to-end build loop' -Skip 'needs network (Steam store/CDN) - the loop calls Get-SteamGameName/New-SteamGameDriver directly; covered piecewise above and in SteamDriverLib.Tests.ps1' { }

# ---------------------------------------------------------------- release.ps1
Section 'release.ps1 (stub helper builds, scratch repo)'

function New-ReleaseRepo([bool]$StubPad = $true) {
    $real = Get-RepoRoot
    $root = New-ScratchRepo 'rel'
    foreach ($d in 'steamos-pad', 'steamos-tls') {
        New-Item -ItemType Directory -Force (Join-Path $root $d) | Out-Null
        foreach ($f in @('install.sh', ("$($d -replace 'steamos-', 'c4').service"), 'README.md')) {
            Copy-Item (Join-Path $real "$d/$f") (Join-Path $root "$d/$f")
        }
    }
    New-Item -ItemType Directory -Force (Join-Path $root 'docs') | Out-Null
    Copy-Item (Join-Path $real 'docs/*.md') (Join-Path $root 'docs')
    foreach ($f in 'README.md', 'SECURITY.md', 'RELEASE_NOTES.md', 'CONTRIBUTING.md') { Copy-Item (Join-Path $real $f) (Join-Path $root $f) }
    # stub the Go builds
    $padBody = if ($StubPad) { "New-Item -ItemType Directory -Force (Join-Path (Split-Path `$PSScriptRoot -Parent) 'dist') | Out-Null; Set-Content (Join-Path (Split-Path `$PSScriptRoot -Parent) 'dist/c4pad') 'bin'" } else { '# stub that produces nothing' }
    Set-Content (Join-Path $root 'tools/build-c4pad.ps1') $padBody
    Set-Content (Join-Path $root 'tools/build-c4tls.ps1') "New-Item -ItemType Directory -Force (Join-Path (Split-Path `$PSScriptRoot -Parent) 'dist') | Out-Null; Set-Content (Join-Path (Split-Path `$PSScriptRoot -Parent) 'dist/c4tls') 'bin'"
    # pre-generated game drivers (as make-game-drivers.ps1 would leave them)
    $dist = Join-Path $root 'dist'
    New-Item -ItemType Directory -Force $dist | Out-Null
    foreach ($n in 'steam-game-620.c4z', 'steam-game-730.c4z', 'steam-game-abc.c4z', 'steam-game-12x.c4z', 'steam-game-.c4z') { Set-Content (Join-Path $dist $n) 'zip' }
    return $root
}

$relVer = '9.9.9-test'; $relName = "Control4-SteamMachine-$relVer"
if ($isWin) {
    $relRoot = New-ReleaseRepo
    $relRun = Invoke-Pwsh @('-File', (Join-Path $relRoot 'tools/release.ps1'), '-Version', $relVer)
    $relZip = Join-Path $relRoot "dist/release/$relName.zip"
}

Test 'release.ps1 succeeds and prints version, zip path, SHA-256' -Skip $winOnly {
    Assert-Equal $relRun.ExitCode 0 $relRun.Output
    Assert-Match $relRun.Output "== release $([regex]::Escape($relVer)) =="
    Assert-Match $relRun.Output 'SHA-256: [0-9A-F]{64}'
    Assert-Match $relRun.Output 'drivers: 2 core \+ 2 games'
    Assert-PathExists $relZip
}
Test 'release zip layout: drivers/, drivers/games/, helpers, docs' -Skip $winOnly {
    $e = Get-ZipEntries $relZip
    foreach ($want in 'drivers/steam-machine.c4z', 'drivers/steam-game-miniapp.c4z', 'drivers/games/steam-game-620.c4z', 'drivers/games/steam-game-730.c4z',
        'steamos-helpers/steamos-pad/c4pad', 'steamos-helpers/steamos-pad/install.sh', 'steamos-helpers/steamos-pad/c4pad.service', 'steamos-helpers/steamos-pad/README.md',
        'steamos-helpers/steamos-tls/c4tls', 'steamos-helpers/steamos-tls/install.sh', 'steamos-helpers/steamos-tls/c4tls.service', 'steamos-helpers/steamos-tls/README.md',
        'README.md', 'SECURITY.md', 'RELEASE_NOTES.md', 'CONTRIBUTING.md', 'docs/GENERATED_DRIVERS.md',
        'docs/INSTALLATION.md', 'docs/TROUBLESHOOTING.md', 'docs/ARCHITECTURE.md') {
        Assert-Contains $e $want
    }
}
Test 'only steam-game-<digits>.c4z files go into drivers/games (template and junk excluded)' -Skip $winOnly {
    $games = @(Get-ZipEntries $relZip | Where-Object { $_ -like 'drivers/games/*' -and $_ -notmatch '/$' } | Sort-Object)
    Assert-Equal $games @('drivers/games/steam-game-620.c4z', 'drivers/games/steam-game-730.c4z')
}
Test 'embedded core drivers are real, valid .c4z packages' -Skip $winOnly {
    $tmp = New-TempDir
    foreach ($n in 'steam-machine', 'steam-game-miniapp') {
        $p = Join-Path $tmp "$n.c4z"
        [System.IO.File]::WriteAllBytes($p, (Read-ZipBytes $relZip "drivers/$n.c4z"))
        Assert-Contains (Get-ZipEntries $p) 'driver.xml'
    }
}
Test '.sha256 file matches the zip and uses "<hash>  <name>.zip" format' -Skip $winOnly {
    $line = (Get-Content (Join-Path $relRoot "dist/release/$relName.zip.sha256") -Raw).Trim()
    Assert-Equal $line "$((Get-FileHash $relZip -Algorithm SHA256).Hash)  $relName.zip"
}
Test 'release zip does not nest itself (no release/ folder or inner .zip)' -Skip $winOnly {
    $e = Get-ZipEntries $relZip
    Assert-Equal @($e | Where-Object { $_ -match '^release/|\.zip$' }).Count 0
}
Test 'fails with "missing build output" when a helper build produces nothing' -Skip $winOnly {
    $r2 = New-ReleaseRepo $false
    $res = Invoke-Pwsh @('-File', (Join-Path $r2 'tools/release.ps1'), '-Version', '0.0.1')
    Assert-True ($res.ExitCode -ne 0)
    Assert-Match $res.Output 'missing build output'
    Assert-PathMissing (Join-Path $r2 'dist/release/Control4-SteamMachine-0.0.1.zip')
}
Test 'every source file release.ps1 copies exists in the real repo' {
    $root = Get-RepoRoot
    foreach ($f in 'README.md', 'SECURITY.md', 'RELEASE_NOTES.md', 'CONTRIBUTING.md', 'docs/GENERATED_DRIVERS.md',
        'steamos-pad/install.sh', 'steamos-pad/c4pad.service', 'steamos-pad/README.md',
        'steamos-tls/install.sh', 'steamos-tls/c4tls.service', 'steamos-tls/README.md') {
        Assert-PathExists (Join-Path $root $f)
    }
}
Test 'release.ps1 default -Version is a semver-ish string' {
    $ast = (Get-ScriptAst (Join-Path $toolsDir 'release.ps1')).Ast
    $def = $ast.ParamBlock.Parameters[0].DefaultValue.Value
    Assert-Match $def '^\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?$'
}
Test 'BUG: release.ps1 works on Linux/macOS pwsh' -Skip 'BUG: release.ps1 builds paths with "$dist\steam-machine.c4z" / "\" separators and "$root\steamos-pad\..." instead of Join-Path, so it only runs on Windows' { }

# ---------------------------------------------------------------- build-c4pad / build-c4tls (static)
Section 'build-c4pad.ps1 / build-c4tls.ps1 (static; need Go, not executed)'
foreach ($case in @(@{ S = 'build-c4pad.ps1'; Dir = 'steamos-pad'; Out = 'c4pad' }, @{ S = 'build-c4tls.ps1'; Dir = 'steamos-tls'; Out = 'c4tls' })) {
    $s = $case.S; $dir = $case.Dir; $out = $case.Out
    Test "$s cross-compiles $dir for linux/amd64 reproducibly and restores the environment" {
        $text = Get-Content (Join-Path $toolsDir $s) -Raw
        Assert-Match $text "Join-Path \`$root '$dir'"
        Assert-Match $text "GOOS = 'linux'"; Assert-Match $text "GOARCH = 'amd64'"; Assert-Match $text "CGO_ENABLED = '0'"
        Assert-Match $text '-mod=readonly'; Assert-Match $text '-trimpath'
        Assert-Match $text "'$out'"
        Assert-True ($text.IndexOf('mod verify') -ge 0 -and $text.IndexOf('mod verify') -lt $text.IndexOf('build -mod')) 'go mod verify must precede go build'
        Assert-Match $text 'finally\s*\{[^}]*Remove-Item Env:GOOS, Env:GOARCH, Env:CGO_ENABLED'
        Assert-Match $text 'Pop-Location'
        Assert-PathExists (Join-Path (Get-RepoRoot) "$dir/go.mod")
    }
}
Test 'build-c4pad/c4tls actual compilation' -Skip 'requires the Go toolchain and module cache (hardcoded C:\Program Files\Go path / network for modules); covered by the Go test jobs' { }

# ---------------------------------------------------------------- make-icons.ps1
Section 'make-icons.ps1 (System.Drawing, Windows-only)'
if ($isWin) {
    $iconRoot = New-ScratchRepo 'icons'
    foreach ($d in 'steam-machine/www/icons', 'steam-game-miniapp/www/icons') { Get-ChildItem (Join-Path $iconRoot $d) -Filter *.png | Remove-Item -Force }
    $iconRun = Invoke-Pwsh @('-File', (Join-Path $iconRoot 'tools/make-icons.ps1'))
}
Test 'make-icons.ps1 runs and writes the full icon set for both drivers' -Skip $winOnly {
    Assert-Equal $iconRun.ExitCode 0 $iconRun.Output
    foreach ($d in 'steam-machine', 'steam-game-miniapp') {
        foreach ($s in 16, 32, 70, 90, 300, 512, 1024) { Assert-PathExists (Join-Path $iconRoot "$d/www/icons/device_$s.png") }
        Assert-PathExists (Join-Path $iconRoot "$d/images/icons/device_sm.png")
        Assert-PathExists (Join-Path $iconRoot "$d/images/icons/device_lg.png")
    }
}
Test 'make-icons.ps1 icons have the right dimensions, transparent corners and distinct main/mini colours' -Skip $winOnly {
    Add-Type -AssemblyName System.Drawing
    foreach ($d in 'steam-machine', 'steam-game-miniapp') {
        foreach ($s in 32, 300, 1024) {
            $img = [System.Drawing.Bitmap]::FromFile((Join-Path $iconRoot "$d/www/icons/device_$s.png"))
            try {
                Assert-Equal $img.Width $s; Assert-Equal $img.Height $s
                Assert-Equal $img.GetPixel(0, 0).A 0 'corner should be transparent (rounded square)'
            } finally { $img.Dispose() }
        }
    }
    $a = [System.Drawing.Bitmap]::FromFile((Join-Path $iconRoot 'steam-machine/www/icons/device_300.png'))
    $b = [System.Drawing.Bitmap]::FromFile((Join-Path $iconRoot 'steam-game-miniapp/www/icons/device_300.png'))
    try {
        $pa = $a.GetPixel(30, 150); $pb = $b.GetPixel(30, 150)
        Assert-True ($pa.R -ne $pb.R -or $pa.G -ne $pb.G -or $pa.B -ne $pb.B) 'main and mini-app backgrounds should differ'
        Assert-Equal "$($pa.R),$($pa.G),$($pa.B)" '23,26,33' 'main driver should use Steam navy'
    } finally { $a.Dispose(); $b.Dispose() }
}
