# Tests for tools/build.ps1 (packages every folder containing driver.xml into dist/<name>.c4z).
# build.ps1 derives its paths from $PSScriptRoot, so we run a COPY of it inside a scratch repo
# (temp dir) -- the real dist/ is never touched.

function Invoke-BuildIn([string]$ScratchRoot) {
    return Invoke-Pwsh @('-File', (Join-Path $ScratchRoot 'tools/build.ps1'))
}

function Add-FixtureDriver([string]$Root, [string]$Name = 'zz-fixture') {
    $d = Join-Path $Root $Name
    New-Item -ItemType Directory -Force (Join-Path $d 'www') | Out-Null
    Set-Content (Join-Path $d 'driver.xml') '<devicedata><name>Fixture</name><version>1</version></devicedata>'
    Set-Content (Join-Path $d 'driver.lua') '-- fixture'
    Set-Content (Join-Path $d 'www/keep.txt') 'keep'
    Set-Content (Join-Path $d 'www/tokenizer.lua') 'not a token file'    # "(\|/)token$" is anchored: must be KEPT
    # strays that must be excluded
    foreach ($f in 'notes.bak', 'x~', 'a.tmp', 'run.log', 'f.orig', '.f.swp', '.DS_Store', 'Thumbs.db', 'settings.json', 'token', 'www/settings.json', 'www/token') {
        Set-Content (Join-Path $d $f) 'secret'
    }
    New-Item -ItemType Directory -Force (Join-Path $d '.git') | Out-Null
    Set-Content (Join-Path $d '.git/config') 'x'
    Set-Content (Join-Path $d '.gitignore') 'x'
    return $d
}

# ---------------------------------------------------------------- real drivers
Section 'build.ps1: real drivers (steam-machine, steam-game-miniapp)'

$pkgRoot = New-ScratchRepo 'repo'
$decoy = Join-Path $pkgRoot 'docs-only'      # folder WITHOUT driver.xml must be ignored
New-Item -ItemType Directory -Force $decoy | Out-Null
Set-Content (Join-Path $decoy 'readme.txt') 'x'
$pkgRun = Invoke-BuildIn $pkgRoot
$pkgDist = Join-Path $pkgRoot 'dist'
$machineZip = Join-Path $pkgDist 'steam-machine.c4z'
$miniZip = Join-Path $pkgDist 'steam-game-miniapp.c4z'

Test 'build.ps1 exits 0 and reports both drivers' {
    Assert-Equal $pkgRun.ExitCode 0 $pkgRun.Output
    Assert-Match $pkgRun.Output 'Packaged steam-machine'
    Assert-Match $pkgRun.Output 'Packaged steam-game-miniapp'
}
Test 'only driver folders get a .c4z (no docs-only.c4z, no tools.c4z)' {
    $names = @(Get-ChildItem $pkgDist -Filter *.c4z | ForEach-Object Name | Sort-Object)
    Assert-Equal $names @('steam-game-miniapp.c4z', 'steam-machine.c4z')
}
Test 'temporary dist/.staging directory is cleaned up' { Assert-PathMissing (Join-Path $pkgDist '.staging') }

foreach ($case in @(@{ N = 'steam-machine'; Z = $machineZip }, @{ N = 'steam-game-miniapp'; Z = $miniZip })) {
    $zip = $case.Z; $n = $case.N
    Test "$n.c4z is a valid zip with driver.xml/driver.lua at the root" {
        $e = Get-ZipEntries $zip
        Assert-Contains $e 'driver.xml'
        Assert-Contains $e 'driver.lua'
    }
    Test "$n.c4z has documentation html + css" {
        $e = Get-ZipEntries $zip
        Assert-Contains $e 'www/documentation.html'
        Assert-Contains $e 'www/documentation.css'
    }
    Test "$n.c4z has the icons referenced by driver.xml" {
        $e = Get-ZipEntries $zip
        foreach ($i in 'sm', 'lg', '16', '32', '70', '90', '300', '512', '1024') { Assert-Contains $e "www/icons/device_$i.png" }
    }
    Test "$n.c4z contains no stray files (.git, Thumbs.db, tests/, .staging, tools/)" {
        $e = Get-ZipEntries $zip
        foreach ($bad in '\.git', 'Thumbs\.db', '^tests/', '^tools/', '\.staging', '\.DS_Store', '\.bak$', 'settings\.json$', '(^|/)token$') {
            $hit = @($e | Where-Object { $_ -match $bad })
            Assert-Equal $hit.Count 0 "entries matching /$bad/: $($hit -join ', ')"
        }
    }
    Test "$n.c4z driver.xml is well-formed XML with key fields" {
        [xml]$x = Read-ZipText $zip 'driver.xml'
        $dd = $x.devicedata
        Assert-True ($dd.name -match '\S') 'name missing'
        Assert-Match $dd.version '^\d+$'
        Assert-Equal $dd.control 'lua_gen'
        Assert-Equal $dd.driver 'DriverWorks'
        Assert-True (@($dd.proxies.proxy).Count -ge 1) 'no <proxy>'
        Assert-Equal $dd.proxies.qty ([string]@($dd.proxies.proxy).Count) '<proxies qty> mismatch'
        Assert-True (@($dd.connections.connection).Count -ge 1) 'no <connection>'
        Assert-Equal $dd.config.script.file 'driver.lua'
    }
    Test "$n.c4z driver.xml/driver.lua are byte-identical to the source" {
        $src = Join-Path (Get-RepoRoot) $n
        foreach ($f in 'driver.xml', 'driver.lua') {
            $a = (Get-FileHash (Join-Path $src $f) -Algorithm SHA256).Hash
            $tmp = Join-Path (New-TempDir) $f
            [System.IO.File]::WriteAllBytes($tmp, (Read-ZipBytes $zip $f))
            Assert-Equal (Get-FileHash $tmp -Algorithm SHA256).Hash $a "$f differs"
        }
    }
    Test "$n.c4z entry set equals the source tree file set" {
        $src = Join-Path (Get-RepoRoot) $n
        $srcFiles = @(Get-ChildItem $src -Recurse -File | ForEach-Object { $_.FullName.Substring($src.Length + 1).Replace('\', '/') } | Sort-Object)
        $zipFiles = @(Get-ZipEntries $zip | Where-Object { $_ -notmatch '/$' } | Sort-Object)
        Assert-Equal $zipFiles $srcFiles
    }
}

Test 'steam-machine.c4z ships the drivers-common-public/ tree' {
    $e = Get-ZipEntries $machineZip
    $dcp = @($e | Where-Object { $_ -like 'drivers-common-public/*' -and $_ -notmatch '/$' })
    Assert-True ($dcp.Count -gt 5) "only $($dcp.Count) files under drivers-common-public/"
    Assert-True (@($e | Where-Object { $_ -like 'drivers-common-public/global/*' }).Count -gt 0) 'no global/'
    Assert-True (@($e | Where-Object { $_ -like 'drivers-common-public/module/*' }).Count -gt 0) 'no module/'
}
Test 'steam-machine driver.xml declares the media_player + avswitch proxies' {
    [xml]$x = Read-ZipText $machineZip 'driver.xml'
    $types = @($x.devicedata.proxies.proxy | ForEach-Object { $_.'#text' })
    Assert-Contains $types 'media_player'
    Assert-Contains $types 'avswitch'
}
Test 'steam-game-miniapp.c4z has the navigator experience icons referenced by driver.xml' {
    [xml]$x = Read-ZipText $miniZip 'driver.xml'
    $e = Get-ZipEntries $miniZip
    $icons = @($x.devicedata.capabilities.navigator_display_option.display_icons.Icon)
    Assert-Equal $icons.Count 5
    foreach ($i in $icons) {
        $rel = $i.'#text' -replace '^controller://driver/[^/]+/', 'www/'
        Assert-Contains $e $rel "icon $($i.'#text')"
    }
}
Test 'steam-game-miniapp.c4z has Game Name and Steam App ID properties' {
    [xml]$x = Read-ZipText $miniZip 'driver.xml'
    $names = @($x.devicedata.config.properties.property | ForEach-Object name)
    Assert-Contains $names 'Game Name'
    Assert-Contains $names 'Steam App ID or URI'
}
Test 'every c4z image reference in driver.xml (small/large/proxy icons) exists in the zip' {
    foreach ($case in @(@{ Z = $machineZip }, @{ Z = $miniZip })) {
        [xml]$x = Read-ZipText $case.Z 'driver.xml'
        $e = Get-ZipEntries $case.Z
        foreach ($rel in @($x.devicedata.small.'#text', $x.devicedata.large.'#text')) {
            Assert-Contains $e "www/$rel" "referenced icon $rel"
        }
    }
}

# ---------------------------------------------------------------- exclusion + behaviour
Section 'build.ps1: exclusion filter, re-runs, failure modes'

$fxRoot = New-ScratchRepo 'repo2' @()
$fx = Add-FixtureDriver $fxRoot
$fxRun = Invoke-BuildIn $fxRoot
$fxZip = Join-Path $fxRoot 'dist/zz-fixture.c4z'

Test 'fixture driver builds' { Assert-Equal $fxRun.ExitCode 0 $fxRun.Output; Assert-PathExists $fxZip }
Test 'stray/sensitive files are excluded and warned about' {
    $e = Get-ZipEntries $fxZip
    foreach ($bad in 'notes.bak', 'x~', 'a.tmp', 'run.log', 'f.orig', '.f.swp', '.DS_Store', 'Thumbs.db', 'settings.json', 'token', 'www/settings.json', 'www/token', '.gitignore', '.git/config') {
        Assert-NotContains $e $bad
    }
    Assert-Match $fxRun.Output 'Excluded from zz-fixture\.c4z'
}
Test 'legitimate files (incl. tokenizer.lua, which only resembles "token") are kept' {
    $e = Get-ZipEntries $fxZip
    foreach ($ok in 'driver.xml', 'driver.lua', 'www/keep.txt', 'www/tokenizer.lua') { Assert-Contains $e $ok }
}
Test 'source folder is not modified by the build (strays still present)' {
    Assert-PathExists (Join-Path $fx 'token')
    Assert-PathExists (Join-Path $fx 'Thumbs.db')
}
Test 'a second run replaces the .c4z (no stale entries from a removed source file)' {
    Remove-Item (Join-Path $fx 'www/keep.txt')
    $r = Invoke-BuildIn $fxRoot
    Assert-Equal $r.ExitCode 0 $r.Output
    Assert-NotContains (Get-ZipEntries $fxZip) 'www/keep.txt'
}
Test 'fails with a clear error when no driver directory exists' {
    $empty = New-ScratchRepo 'repo3' @()
    $r = Invoke-BuildIn $empty
    Assert-True ($r.ExitCode -ne 0) 'expected non-zero exit'
    Assert-Match $r.Output 'No driver directories'
}
Test 'directory without driver.xml is not packaged' {
    Assert-PathMissing (Join-Path $pkgDist 'docs-only.c4z')
}

# Real defect: the exclusion regex is applied to the FULL staged path, so a repo that lives
# under any directory whose name contains ".git" (e.g. C:\src\.github-work\...) / ends in
# ".log"-style segments has EVERY file excluded and ships an empty package.
Test 'BUG: build in a checkout whose path contains ".git" still packages files' -Skip 'BUG: build.ps1 matches $excludePattern against $_.FullName (not the path relative to the stage dir); a parent dir containing ".git" excludes everything' {
    $r = New-ScratchRepo 'work.github' @('steam-game-miniapp')
    $res = Invoke-BuildIn $r
    Assert-Equal $res.ExitCode 0 $res.Output
    Assert-Contains (Get-ZipEntries (Join-Path $r 'dist/steam-game-miniapp.c4z')) 'driver.xml'
}
