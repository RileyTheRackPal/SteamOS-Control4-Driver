# Tests for tools/steam-driver-lib.ps1. All network access (Invoke-RestMethod / Invoke-WebRequest /
# the Get-*FromUrl helpers) is replaced by in-process stubs; nothing here touches the network.
# The lib uses System.Drawing, so the whole file is skipped where the lib cannot be loaded (Linux
# without libgdiplus).

$libPath = Join-Path (Get-RepoRoot) 'tools/steam-driver-lib.ps1'
$libSkip = $null
try {
    . $libPath
    $null = New-Object System.Drawing.Bitmap(1, 1)
} catch {
    $libSkip = "System.Drawing unavailable on this platform: $($_.Exception.Message)"
}
if ($libSkip) { Write-Host "  (lib not loadable: $libSkip)" -ForegroundColor Yellow }

# ---- local helpers ---------------------------------------------------------
function New-SolidBitmap([int]$W, [int]$H, [int[]]$Rgb, [int]$Alpha = 255) {
    $b = New-Object System.Drawing.Bitmap($W, $H)
    $g = [System.Drawing.Graphics]::FromImage($b)
    $g.Clear([System.Drawing.Color]::FromArgb($Alpha, $Rgb[0], $Rgb[1], $Rgb[2]))
    $g.Dispose()
    return $b
}
function ConvertTo-PngBytes([System.Drawing.Bitmap]$Bmp) {
    $ms = New-Object System.IO.MemoryStream
    $Bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    return , $ms.ToArray()
}
# Build a .ico whose frames are @{ W=<px>; Data=<byte[]> } (W=256 is stored as 0, per the ICO spec).
function New-IcoBytes([object[]]$Frames, [uint16]$Type = 1) {
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    $bw.Write([uint16]0); $bw.Write([uint16]$Type); $bw.Write([uint16]$Frames.Count)
    $off = 6 + 16 * $Frames.Count
    foreach ($f in $Frames) {
        $wb = if ($f.W -ge 256) { 0 } else { $f.W }
        $bw.Write([byte]$wb); $bw.Write([byte]$wb); $bw.Write([byte]0); $bw.Write([byte]0)
        $bw.Write([uint16]1); $bw.Write([uint16]32)
        $bw.Write([uint32]$f.Data.Length); $bw.Write([uint32]$off)
        $off += $f.Data.Length
    }
    foreach ($f in $Frames) { $bw.Write([byte[]]$f.Data) }
    $bw.Flush()
    return , $ms.ToArray()
}
function Assert-Pixel($Bmp, [int]$X, [int]$Y, [int[]]$Rgb, [int]$Tol = 4) {
    $p = $Bmp.GetPixel($X, $Y)
    if ([Math]::Abs($p.R - $Rgb[0]) -gt $Tol -or [Math]::Abs($p.G - $Rgb[1]) -gt $Tol -or [Math]::Abs($p.B - $Rgb[2]) -gt $Tol) {
        throw "pixel($X,$Y) = ($($p.R),$($p.G),$($p.B)) expected ~($($Rgb -join ','))"
    }
}
$cNavy = @(23, 26, 33); $cRed = @(255, 0, 0); $cGreen = @(0, 255, 0); $cBlue = @(0, 0, 255)

# ---------------------------------------------------------------- Get-IcoBestPngFrame
Section 'steam-driver-lib: Get-IcoBestPngFrame (pure ICO parsing)'

Test 'returns null for null / too-short input' -Skip $libSkip {
    Assert-Null (Get-IcoBestPngFrame $null)
    Assert-Null (Get-IcoBestPngFrame ([byte[]]@()))
    Assert-Null (Get-IcoBestPngFrame ([byte[]]@(0, 0, 1, 0, 1)))
}
Test 'returns null when the type field is not 1 (e.g. a .cur)' -Skip $libSkip {
    $png = ConvertTo-PngBytes (New-SolidBitmap 256 256 $cRed)
    Assert-Null (Get-IcoBestPngFrame (New-IcoBytes @(@{ W = 256; Data = $png }) -Type 2))
}
Test 'picks the largest PNG frame (>=128px)' -Skip $libSkip {
    $p64 = ConvertTo-PngBytes (New-SolidBitmap 64 64 $cRed)
    $p128 = ConvertTo-PngBytes (New-SolidBitmap 128 128 $cGreen)
    $p256 = ConvertTo-PngBytes (New-SolidBitmap 256 256 $cBlue)
    $bmp = Get-IcoBestPngFrame (New-IcoBytes @(@{ W = 64; Data = $p64 }, @{ W = 256; Data = $p256 }, @{ W = 128; Data = $p128 }))
    Assert-NotNull $bmp
    Assert-Equal $bmp.Width 256
    Assert-Pixel $bmp 10 10 $cBlue
}
Test 'width byte 0 is interpreted as 256 and 128px is accepted (boundary)' -Skip $libSkip {
    $p128 = ConvertTo-PngBytes (New-SolidBitmap 128 128 $cGreen)
    $bmp = Get-IcoBestPngFrame (New-IcoBytes @(@{ W = 128; Data = $p128 }))
    Assert-NotNull $bmp
    Assert-Equal $bmp.Width 128
}
Test 'returns null when only small (<128px) PNG frames exist' -Skip $libSkip {
    $p64 = ConvertTo-PngBytes (New-SolidBitmap 64 64 $cRed)
    $p32 = ConvertTo-PngBytes (New-SolidBitmap 32 32 $cRed)
    Assert-Null (Get-IcoBestPngFrame (New-IcoBytes @(@{ W = 64; Data = $p64 }, @{ W = 32; Data = $p32 })))
}
Test 'ignores non-PNG (BMP-style) frames even when larger' -Skip $libSkip {
    $fakeBmp = [byte[]](@(40, 0, 0, 0) + (1..60 | ForEach-Object { 7 }))   # DIB header, not a PNG signature
    $p128 = ConvertTo-PngBytes (New-SolidBitmap 128 128 $cGreen)
    $bmp = Get-IcoBestPngFrame (New-IcoBytes @(@{ W = 256; Data = $fakeBmp }, @{ W = 128; Data = $p128 }))
    Assert-NotNull $bmp
    Assert-Equal $bmp.Width 128
    Assert-Null (Get-IcoBestPngFrame (New-IcoBytes @(@{ W = 256; Data = $fakeBmp })))
}
Test 'tolerates a directory that claims more entries than the file holds / bad offsets' -Skip $libSkip {
    $p256 = ConvertTo-PngBytes (New-SolidBitmap 256 256 $cRed)
    $ico = New-IcoBytes @(@{ W = 256; Data = $p256 })
    $ico[4] = 5   # claim 5 frames; 4 directory slots run off the end of the buffer
    Assert-NotNull (Get-IcoBestPngFrame $ico)
    $bad = New-IcoBytes @(@{ W = 256; Data = $p256 })
    [BitConverter]::GetBytes([uint32]0x7FFFFFF0).CopyTo($bad, 6 + 12)   # offset far outside the file
    Assert-Null (Get-IcoBestPngFrame $bad)
}

# ---------------------------------------------------------------- Save-Resized
Section 'steam-driver-lib: Save-Resized'

Test 'writes a PNG of the requested size and creates missing parent directories' -Skip $libSkip {
    $dir = Join-Path (New-TempDir) 'a/b/c'
    $m = New-SolidBitmap 1024 1024 $cRed
    foreach ($s in 16, 70, 512) {
        $p = Join-Path $dir "icon_$s.png"
        Save-Resized $m $p $s
        $img = [System.Drawing.Image]::FromFile($p)
        try {
            Assert-Equal $img.Width $s; Assert-Equal $img.Height $s
            Assert-True ($img.RawFormat.Guid -eq [System.Drawing.Imaging.ImageFormat]::Png.Guid) 'not PNG'
        } finally { $img.Dispose() }
    }
    $m.Dispose()
}

# ---------------------------------------------------------------- Get-Bytes / Get-SteamGameName / Get-BitmapFromUrl (cmdlets stubbed)
Section 'steam-driver-lib: network wrappers with stubbed Invoke-WebRequest / Invoke-RestMethod'

$global:Mock = @{ Urls = [System.Collections.Generic.List[string]]::new() }

Test 'Get-Bytes returns the body on HTTP 200 and sends the tool user-agent' -Skip $libSkip {
    $global:Mock.Ua = $null
    function Invoke-WebRequest { param($Uri, $TimeoutSec, $UserAgent, $ErrorAction) $global:Mock.Ua = $UserAgent; [pscustomobject]@{ StatusCode = 200; Content = [byte[]](1, 2, 3) } }
    try {
        $b = Get-Bytes 'http://example.invalid/x'
        Assert-True ($b -is [byte[]]) 'expected byte[]'
        Assert-Equal @($b) @(1, 2, 3)
        Assert-Equal $global:Mock.Ua 'Control4-SteamMachine-driver-tool'
    } finally { Remove-Item function:Invoke-WebRequest }
}
Test 'Get-Bytes returns null on non-200, empty body, or exception' -Skip $libSkip {
    try {
        function Invoke-WebRequest { param($Uri, $TimeoutSec, $UserAgent, $ErrorAction) [pscustomobject]@{ StatusCode = 404; Content = [byte[]](1) } }
        Assert-Null (Get-Bytes 'u')
        function Invoke-WebRequest { param($Uri, $TimeoutSec, $UserAgent, $ErrorAction) [pscustomobject]@{ StatusCode = 200; Content = [byte[]]@() } }
        Assert-Null (Get-Bytes 'u')
        function Invoke-WebRequest { param($Uri, $TimeoutSec, $UserAgent, $ErrorAction) throw 'offline' }
        Assert-Null (Get-Bytes 'u')
    } finally { Remove-Item function:Invoke-WebRequest }
}
Test 'Get-SteamGameName returns the store name on success' -Skip $libSkip {
    function Invoke-RestMethod { param($Uri, $TimeoutSec, $UserAgent) $global:Mock.Uri = $Uri; [pscustomobject]@{ '620' = [pscustomobject]@{ success = $true; data = [pscustomobject]@{ name = 'Portal 2' } } } }
    try {
        Assert-Equal (Get-SteamGameName '620') 'Portal 2'
        Assert-Match $global:Mock.Uri 'appids=620(&|$)'
    } finally { Remove-Item function:Invoke-RestMethod }
}
Test 'Get-SteamGameName falls back to "Steam Game <id>" on failure / success=false / empty name / exception' -Skip $libSkip {
    try {
        function Invoke-RestMethod { param($Uri, $TimeoutSec, $UserAgent) [pscustomobject]@{ '9' = [pscustomobject]@{ success = $false } } }
        Assert-Equal (Get-SteamGameName '9') 'Steam Game 9'
        function Invoke-RestMethod { param($Uri, $TimeoutSec, $UserAgent) [pscustomobject]@{ '9' = [pscustomobject]@{ success = $true; data = [pscustomobject]@{ name = '' } } } }
        Assert-Equal (Get-SteamGameName '9') 'Steam Game 9'
        function Invoke-RestMethod { param($Uri, $TimeoutSec, $UserAgent) throw 'offline' }
        Assert-Equal (Get-SteamGameName '9') 'Steam Game 9'
    } finally { Remove-Item function:Invoke-RestMethod }
}
Test 'Get-ClientIconBitmap: no clienticon hash -> null; hash -> fetches <appid>/<hash>.ico and parses it' -Skip $libSkip {
    $png = ConvertTo-PngBytes (New-SolidBitmap 256 256 $cGreen)
    $ico = New-IcoBytes @(@{ W = 256; Data = $png })
    $global:Mock.Ico = $ico; $global:Mock.Hash = $null; $global:Mock.Urls.Clear()
    function Invoke-RestMethod { param($Uri, $TimeoutSec, $UserAgent) [pscustomobject]@{ data = [pscustomobject]@{ '620' = [pscustomobject]@{ common = [pscustomobject]@{ clienticon = $global:Mock.Hash } } } } }
    function Get-Bytes([string]$Url) { $global:Mock.Urls.Add($Url); return , $global:Mock.Ico }
    try {
        Assert-Null (Get-ClientIconBitmap '620')
        Assert-Equal $global:Mock.Urls.Count 0 'must not download when there is no hash'
        $global:Mock.Hash = 'abc123'
        $bmp = Get-ClientIconBitmap '620'
        Assert-NotNull $bmp
        Assert-Equal $bmp.Width 256
        Assert-Equal $global:Mock.Urls[0] 'https://cdn.cloudflare.steamstatic.com/steamcommunity/public/images/apps/620/abc123.ico'
        $global:Mock.Ico = $null
        Assert-Null (Get-ClientIconBitmap '620') 'download failure -> null'
    } finally { Remove-Item function:Invoke-RestMethod, function:Get-Bytes }
}
if (-not $libSkip) { . $libPath }   # restore any lib function shadowed above
Test 'Get-BitmapFromUrl: decodes image bytes; garbage or missing bytes -> null' -Skip $libSkip {
    $png = ConvertTo-PngBytes (New-SolidBitmap 40 20 $cRed)
    $global:Mock.Bytes = $png
    function Get-Bytes([string]$Url) { return , $global:Mock.Bytes }
    try {
        $img = Get-BitmapFromUrl 'u'
        Assert-Equal $img.Width 40; Assert-Equal $img.Height 20
        $global:Mock.Bytes = [byte[]](1, 2, 3, 4, 5)
        Assert-Null (Get-BitmapFromUrl 'u')
        $global:Mock.Bytes = $null
        Assert-Null (Get-BitmapFromUrl 'u')
    } finally { Remove-Item function:Get-Bytes }
}
if (-not $libSkip) { . $libPath }

# ---------------------------------------------------------------- Get-SteamMasterSquare (image fetchers stubbed)
Section 'steam-driver-lib: Get-SteamMasterSquare compositing + source selection'

$global:Mock.Icon = $null; $global:Mock.UrlImages = @{}; $global:Mock.IconCalls = 0
function Get-ClientIconBitmap([string]$AppId) { $global:Mock.IconCalls++; return $global:Mock.Icon }
function Get-BitmapFromUrl([string]$Url) {
    $global:Mock.Urls.Add($Url)
    foreach ($k in $global:Mock.UrlImages.Keys) { if ($Url -like "*/$k") { return $global:Mock.UrlImages[$k] } }
    return $null
}
function Reset-Mock { $global:Mock.Icon = $null; $global:Mock.UrlImages = @{}; $global:Mock.IconCalls = 0; $global:Mock.Urls.Clear() }

Test 'auto: clienticon wins -> 1024x1024, navy margin, icon scaled with 6% inset' -Skip $libSkip {
    Reset-Mock
    $global:Mock.Icon = New-SolidBitmap 256 256 $cRed
    $art = Get-SteamMasterSquare '620'
    Assert-Equal $art.Source 'clienticon'
    Assert-Equal $art.Bitmap.Width 1024; Assert-Equal $art.Bitmap.Height 1024
    Assert-Pixel $art.Bitmap 2 2 $cNavy            # outside the inset
    Assert-Pixel $art.Bitmap 1021 1021 $cNavy
    Assert-Pixel $art.Bitmap 512 512 $cRed
    Assert-Pixel $art.Bitmap 90 90 $cRed           # just inside the inset (61px)
    Assert-Equal $global:Mock.Urls.Count 0 'no URL fetches needed when the icon exists'
    $art.Bitmap.Dispose()
}
Test 'auto: falls back to logo_2x, contained within ~86% and centred' -Skip $libSkip {
    Reset-Mock
    $global:Mock.UrlImages['logo_2x.png'] = New-SolidBitmap 400 100 $cGreen
    $art = Get-SteamMasterSquare '620'
    Assert-Equal $art.Source 'logo'
    Assert-Equal $global:Mock.IconCalls 1
    Assert-Pixel $art.Bitmap 512 512 $cGreen
    Assert-Pixel $art.Bitmap 512 300 $cNavy        # wide logo: letterboxed above/below
    Assert-Pixel $art.Bitmap 20 512 $cNavy         # and ~7% margin left/right
    Assert-Pixel $art.Bitmap 100 512 $cGreen       # 86% width spans x in [72,952]
    $art.Bitmap.Dispose()
}
Test 'logo.png is tried only after logo_2x.png fails' -Skip $libSkip {
    Reset-Mock
    $global:Mock.UrlImages['logo.png'] = New-SolidBitmap 100 100 $cGreen
    $art = Get-SteamMasterSquare '77' 'logo'
    Assert-Equal $art.Source 'logo'
    Assert-Match $global:Mock.Urls[0] '/steam/apps/77/logo_2x\.png$'
    Assert-Match $global:Mock.Urls[1] '/steam/apps/77/logo\.png$'
    $art.Bitmap.Dispose()
}
Test 'auto: falls back to boxart, centre-cropped to a square' -Skip $libSkip {
    Reset-Mock
    $wide = New-Object System.Drawing.Bitmap(800, 400)
    $g = [System.Drawing.Graphics]::FromImage($wide)
    $g.FillRectangle([System.Drawing.Brushes]::Blue, 0, 0, 400, 400)
    $g.FillRectangle([System.Drawing.Brushes]::Red, 400, 0, 400, 400)
    $g.Dispose()
    $global:Mock.UrlImages['header.jpg'] = $wide
    $art = Get-SteamMasterSquare '5'
    Assert-Equal $art.Source 'boxart'
    # central 400x400 crop = x in [200,600): left half blue, right half red
    Assert-Pixel $art.Bitmap 100 512 $cBlue
    Assert-Pixel $art.Bitmap 900 512 $cRed
    $art.Bitmap.Dispose()
}
Test 'boxart fallback chain order: library 2x -> library -> capsule 616 -> header -> capsule 231' -Skip $libSkip {
    Reset-Mock
    $r = Get-SteamMasterSquare '5' 'boxart'
    Assert-Null $r 'all sources missing -> null'
    $assets = @($global:Mock.Urls | ForEach-Object { ($_ -split '/')[-1] })
    Assert-Equal $assets @('library_600x900_2x.jpg', 'library_600x900.jpg', 'capsule_616x353.jpg', 'header.jpg', 'capsule_231x87.jpg')
}
Test 'Style=boxart skips icon + logo; Style=logo skips icon; Style=icon still falls through to logo/boxart' -Skip $libSkip {
    Reset-Mock; $null = Get-SteamMasterSquare '5' 'boxart'
    Assert-Equal $global:Mock.IconCalls 0
    Assert-Equal @($global:Mock.Urls | Where-Object { $_ -match 'logo' }).Count 0
    Reset-Mock; $null = Get-SteamMasterSquare '5' 'logo'
    Assert-Equal $global:Mock.IconCalls 0
    Assert-Equal @($global:Mock.Urls | Where-Object { $_ -match 'logo' }).Count 2
    Reset-Mock; $null = Get-SteamMasterSquare '5' 'icon'
    Assert-Equal $global:Mock.IconCalls 1
    Assert-Equal @($global:Mock.Urls | Where-Object { $_ -match 'logo' }).Count 2
}
Test 'returns null when no art exists at all' -Skip $libSkip {
    Reset-Mock
    Assert-Null (Get-SteamMasterSquare '404')
}

# ---------------------------------------------------------------- New-SteamGameDriver
Section 'steam-driver-lib: New-SteamGameDriver (per-game .c4z packaging, art + name stubbed)'

$global:Mock.Source = 'mockart'; $global:Mock.NoArt = $false; $global:Mock.NameCalls = 0
function Get-SteamMasterSquare([string]$AppId, [string]$Style = 'auto') {
    $global:Mock.LastStyle = $Style
    if ($global:Mock.NoArt) { return $null }
    return @{ Bitmap = (New-SolidBitmap 1024 1024 $cRed); Source = $global:Mock.Source }
}
function Get-SteamGameName([string]$AppId) { $global:Mock.NameCalls++; return "Looked Up $AppId" }

function New-GameRoot {
    $r = New-TempDir 'c4game'
    Copy-Item (Join-Path (Get-RepoRoot) 'steam-game-miniapp') $r -Recurse
    return $r
}

if (-not $libSkip) {
    $gRoot = New-GameRoot
    $tplXmlHash = (Get-FileHash (Join-Path $gRoot 'steam-game-miniapp/driver.xml')).Hash
    $tplIcons = @(Get-ChildItem (Join-Path $gRoot 'steam-game-miniapp/www/icons') -Recurse -Filter *.png).Count
    $src = New-SteamGameDriver -AppId '620' -Name 'Portal 2' -Style 'logo' -Root $gRoot
    $gZip = Join-Path $gRoot 'dist/steam-game-620.c4z'
}

Test 'returns the art source label and forwards Style' -Skip $libSkip {
    Assert-Equal $src 'mockart'
    Assert-Equal $global:Mock.LastStyle 'logo'
}
Test 'output is named dist/steam-game-<appid>.c4z and .gamestage is cleaned up' -Skip $libSkip {
    Assert-PathExists $gZip
    Assert-PathMissing (Join-Path $gRoot 'dist/.gamestage')
    Assert-Equal @(Get-ChildItem (Join-Path $gRoot 'dist') -File | ForEach-Object Name) @('steam-game-620.c4z')
}
Test 'zip has driver.xml/driver.lua/docs at root and only the regenerated icon set' -Skip $libSkip {
    $e = Get-ZipEntries $gZip
    foreach ($f in 'driver.xml', 'driver.lua', 'www/documentation.html', 'www/documentation.css') { Assert-Contains $e $f }
    $pngs = @($e | Where-Object { $_ -like '*.png' } | Sort-Object)
    $want = @('www/icons/device/experience_1024.png', 'www/icons/device/experience_300.png', 'www/icons/device/experience_512.png',
        'www/icons/device/experience_70.png', 'www/icons/device/experience_90.png', 'www/icons/device_lg.png', 'www/icons/device_sm.png') | Sort-Object
    Assert-Equal $pngs $want 'template placeholder PNGs must not leak into per-game drivers'
}
Test 'embedded icons have the sizes their names claim and carry the art' -Skip $libSkip {
    $sizes = @{ 'www/icons/device/experience_1024.png' = 1024; 'www/icons/device/experience_512.png' = 512; 'www/icons/device/experience_300.png' = 300
        'www/icons/device/experience_90.png' = 90; 'www/icons/device/experience_70.png' = 70; 'www/icons/device_sm.png' = 16; 'www/icons/device_lg.png' = 32 }
    foreach ($k in $sizes.Keys) {
        $ms = New-Object System.IO.MemoryStream (, (Read-ZipBytes $gZip $k))
        $img = [System.Drawing.Bitmap]::FromStream($ms)
        try { Assert-Equal $img.Width $sizes[$k] $k; Assert-Pixel $img ([int]($sizes[$k] / 2)) ([int]($sizes[$k] / 2)) $cRed } finally { $img.Dispose() }
    }
}
Test 'driver.xml: name/model/properties/version/dates templated for the game' -Skip $libSkip {
    [xml]$x = Read-ZipText $gZip 'driver.xml'
    $dd = $x.devicedata
    Assert-Equal $dd.name 'Portal 2 (Steam)'
    Assert-Equal $dd.model 'Portal 2'
    Assert-Equal $dd.version '2'
    Assert-Match $dd.created '^\d{2}[/.]\d{2}[/.]\d{4} \d{2}:\d{2}$'
    Assert-Equal $dd.created $dd.modified
    $props = @{}; foreach ($p in $dd.config.properties.property) { $props[$p.name] = $p.default }
    Assert-Equal $props['Game Name'] 'Portal 2'
    Assert-Equal $props['Steam App ID or URI'] '620'
    Assert-Equal $props['Launch URI'] ''
}
Test 'driver.xml: navigator icon URLs point at the per-game driver name, not the template' -Skip $libSkip {
    [xml]$x = Read-ZipText $gZip 'driver.xml'
    $icons = @($x.devicedata.capabilities.navigator_display_option.display_icons.Icon)
    Assert-Equal $icons.Count 5
    foreach ($i in $icons) {
        Assert-Match $i.'#text' '^controller://driver/steam-game-620/icons/device/experience_\d+\.png$'
    }
    Assert-False ((Read-ZipText $gZip 'driver.xml') -match 'steam-game-miniapp') 'template name leaked'
}
Test 'template folder is left untouched by packaging' -Skip $libSkip {
    Assert-Equal (Get-FileHash (Join-Path $gRoot 'steam-game-miniapp/driver.xml')).Hash $tplXmlHash
    Assert-Equal @(Get-ChildItem (Join-Path $gRoot 'steam-game-miniapp/www/icons') -Recurse -Filter *.png).Count $tplIcons
}
Test 'omitted -Name triggers a store lookup; re-running is idempotent (version stays template+1)' -Skip $libSkip {
    $global:Mock.NameCalls = 0
    $null = New-SteamGameDriver -AppId '730' -Root $gRoot
    $null = New-SteamGameDriver -AppId '730' -Root $gRoot
    Assert-Equal $global:Mock.NameCalls 2
    [xml]$x = Read-ZipText (Join-Path $gRoot 'dist/steam-game-730.c4z') 'driver.xml'
    Assert-Equal $x.devicedata.name 'Looked Up 730 (Steam)'
    Assert-Equal $x.devicedata.version '2'
}
Test 'explicit -Name does not trigger a lookup' -Skip $libSkip {
    $global:Mock.NameCalls = 0
    $null = New-SteamGameDriver -AppId '731' -Name 'X' -Root $gRoot
    Assert-Equal $global:Mock.NameCalls 0
}
Test 'names with XML metacharacters and quotes round-trip safely' -Skip $libSkip {
    $weird = "Tom & Jerry <3> `"Q`" 'x'"
    $null = New-SteamGameDriver -AppId '12' -Name $weird -Root $gRoot
    [xml]$x = Read-ZipText (Join-Path $gRoot 'dist/steam-game-12.c4z') 'driver.xml'
    Assert-Equal $x.devicedata.model $weird
    Assert-Equal $x.devicedata.name "$weird (Steam)"
}
Test 'throws "No art found" and leaves no half-built output when art is unavailable' -Skip $libSkip {
    $global:Mock.NoArt = $true
    try {
        Assert-Throws { New-SteamGameDriver -AppId '999' -Name 'Nope' -Root $gRoot } 'No art found for AppID 999'
        Assert-PathMissing (Join-Path $gRoot 'dist/steam-game-999.c4z')
        Assert-PathMissing (Join-Path $gRoot 'dist/.gamestage')
    } finally { $global:Mock.NoArt = $false }
}
Test 'AppId and Root are mandatory parameters' -Skip $libSkip {
    $cmd = Get-Command New-SteamGameDriver
    Assert-True $cmd.Parameters['AppId'].Attributes.Mandatory 'AppId should be mandatory'
    Assert-True $cmd.Parameters['Root'].Attributes.Mandatory 'Root should be mandatory'
}
Test 'BUG: New-SteamGameDriver accepts a non-numeric AppId (path traversal in output name)' -Skip 'BUG: validation lives only in make-game-driver.ps1 ([ValidatePattern]); the shared lib New-SteamGameDriver writes dist/steam-game-$AppId.c4z for any string, e.g. "..\..\x"' {
    Assert-Throws { New-SteamGameDriver -AppId '..\..\evil' -Name 'x' -Root $gRoot } 'AppId'
}

# put the real lib back so later test files see unstubbed functions
if (-not $libSkip) { . $libPath }
