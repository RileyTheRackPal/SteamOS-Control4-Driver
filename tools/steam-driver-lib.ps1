# Shared library for building Steam game mini-drivers. Dot-source it:
#   . "$PSScriptRoot/steam-driver-lib.ps1"
# Exposes: Get-SteamGameName, Get-SteamMasterSquare, New-SteamGameDriver
Add-Type -AssemblyName System.Drawing

$script:UA = 'Control4-SteamMachine-driver-tool'
$script:CDN = 'https://cdn.cloudflare.steamstatic.com'
$script:Navy = [System.Drawing.Color]::FromArgb(255, 23, 26, 33)  # Steam dark backdrop

function Get-Bytes([string]$Url) {
    try {
        $r = Invoke-WebRequest -Uri $Url -TimeoutSec 25 -UserAgent $script:UA -ErrorAction Stop
        if ($r.StatusCode -eq 200 -and $r.Content.Length -gt 0) { return , $r.Content }
    } catch { }
    return $null
}

function Get-SteamGameName([string]$AppId) {
    try {
        $r = Invoke-RestMethod -Uri "https://store.steampowered.com/api/appdetails?appids=$AppId&filters=basic&l=en&cc=us" -TimeoutSec 25 -UserAgent $script:UA
        $d = $r.$AppId
        if ($d.success -and $d.data.name) { return [string]$d.data.name }
    } catch { }
    return "Steam Game $AppId"
}

# Extract the largest PNG-compressed frame from a Windows .ico byte array.
# (System.Drawing.Icon mis-picks frames, so we parse the ICONDIR ourselves.)
function Get-IcoBestPngFrame([byte[]]$Bytes) {
    if (-not $Bytes -or $Bytes.Length -lt 6) { return $null }
    if ([BitConverter]::ToUInt16($Bytes, 2) -ne 1) { return $null }  # type 1 = icon
    $count = [BitConverter]::ToUInt16($Bytes, 4)
    $bestW = -1; $bestOff = 0; $bestLen = 0
    for ($i = 0; $i -lt $count; $i++) {
        $e = 6 + $i * 16
        if ($e + 16 -gt $Bytes.Length) { break }
        $w = $Bytes[$e]; if ($w -eq 0) { $w = 256 }
        $len = [BitConverter]::ToUInt32($Bytes, $e + 8)
        $off = [BitConverter]::ToUInt32($Bytes, $e + 12)
        if ($off + 8 -gt $Bytes.Length) { continue }
        $isPng = ($Bytes[$off] -eq 0x89 -and $Bytes[$off + 1] -eq 0x50 -and $Bytes[$off + 2] -eq 0x4E -and $Bytes[$off + 3] -eq 0x47)
        if ($isPng -and $w -gt $bestW) { $bestW = $w; $bestOff = $off; $bestLen = $len }
    }
    if ($bestW -ge 128) {
        $ms = New-Object System.IO.MemoryStream($Bytes, [int]$bestOff, [int]$bestLen)
        return [System.Drawing.Bitmap]::FromStream($ms)  # the frame is a standalone PNG blob
    }
    return $null
}

function Get-ClientIconBitmap([string]$AppId) {
    try {
        $info = Invoke-RestMethod -Uri "https://api.steamcmd.net/v1/info/$AppId" -TimeoutSec 25 -UserAgent $script:UA
        $hash = $info.data.$AppId.common.clienticon
        if (-not $hash) { return $null }
        $bytes = Get-Bytes "$script:CDN/steamcommunity/public/images/apps/$AppId/$hash.ico"
        if (-not $bytes) { return $null }
        return Get-IcoBestPngFrame $bytes
    } catch { return $null }
}

function Get-BitmapFromUrl([string]$Url) {
    $bytes = Get-Bytes $Url
    if (-not $bytes) { return $null }
    try {
        $ms = New-Object System.IO.MemoryStream (, $bytes)
        return [System.Drawing.Image]::FromStream($ms)
    } catch { return $null }
}

# Returns a 1024x1024 opaque square "master" bitmap + the source label, trying:
# icon (official square clienticon) -> logo (wordmark on bg) -> boxart (portrait crop).
# Style 'boxart'/'logo'/'icon' forces a source; 'auto' (default) runs the chain.
function Get-SteamMasterSquare([string]$AppId, [string]$Style = 'auto') {
    $size = 1024
    $master = New-Object System.Drawing.Bitmap($size, $size)
    $g = [System.Drawing.Graphics]::FromImage($master)
    $g.InterpolationMode = 'HighQualityBicubic'
    $g.PixelOffsetMode = 'HighQuality'
    $g.Clear($script:Navy)

    $img = $null; $src = $null

    if ($Style -in 'auto', 'icon') {
        $img = Get-ClientIconBitmap $AppId
        if ($img) {
            $src = 'clienticon'
            # square source: scale to fill the tile (small inset so it breathes)
            $inset = [int]($size * 0.06)
            $g.DrawImage($img, $inset, $inset, $size - 2 * $inset, $size - 2 * $inset)
        }
    }
    if (-not $img -and $Style -in 'auto', 'icon', 'logo') {
        $img = Get-BitmapFromUrl "$script:CDN/steam/apps/$AppId/logo_2x.png"
        if (-not $img) { $img = Get-BitmapFromUrl "$script:CDN/steam/apps/$AppId/logo.png" }
        if ($img) {
            $src = 'logo'
            # wide transparent wordmark: contain within ~86% width, center
            $maxW = $size * 0.86; $maxH = $size * 0.86
            $scale = [Math]::Min($maxW / $img.Width, $maxH / $img.Height)
            $w = [int]($img.Width * $scale); $h = [int]($img.Height * $scale)
            $g.DrawImage($img, [int](($size - $w) / 2), [int](($size - $h) / 2), $w, $h)
        }
    }
    if (-not $img) {
        # boxart fallback chain (portrait -> capsule -> header)
        foreach ($asset in 'library_600x900_2x.jpg', 'library_600x900.jpg', 'capsule_616x353.jpg', 'header.jpg', 'capsule_231x87.jpg') {
            $img = Get-BitmapFromUrl "$script:CDN/steam/apps/$AppId/$asset"
            if ($img) { break }
        }
        if ($img) {
            $src = 'boxart'
            $side = [Math]::Min($img.Width, $img.Height)
            $sx = [int](($img.Width - $side) / 2); $sy = [int](($img.Height - $side) / 2)
            $srcRect = New-Object System.Drawing.Rectangle($sx, $sy, $side, $side)
            $dstRect = New-Object System.Drawing.Rectangle(0, 0, $size, $size)
            $g.DrawImage($img, $dstRect, $srcRect, [System.Drawing.GraphicsUnit]::Pixel)
        }
    }

    $g.Dispose()
    if ($img) { $img.Dispose() }
    if (-not $src) { $master.Dispose(); return $null }
    return @{ Bitmap = $master; Source = $src }
}

function Save-Resized([System.Drawing.Bitmap]$Master, [string]$Path, [int]$Size) {
    $bmp = New-Object System.Drawing.Bitmap($Size, $Size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = 'HighQualityBicubic'
    $g.PixelOffsetMode = 'HighQuality'
    $g.DrawImage($Master, 0, 0, $Size, $Size)
    $g.Dispose()
    New-Item -ItemType Directory -Force (Split-Path $Path) | Out-Null
    $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}

# Build one per-game .c4z. Returns the source label used for the icon.
function New-SteamGameDriver {
    param(
        [Parameter(Mandatory)][string]$AppId,
        [string]$Name,
        [string]$Style = 'auto',
        [Parameter(Mandatory)][string]$Root
    )
    $template = Join-Path $Root 'steam-game-miniapp'
    $dist = Join-Path $Root 'dist'
    $basename = "steam-game-$AppId"
    New-Item -ItemType Directory -Force $dist | Out-Null

    if (-not $Name) { $Name = Get-SteamGameName $AppId }

    $art = Get-SteamMasterSquare $AppId $Style
    if (-not $art) { throw "No art found for AppID $AppId" }
    $master = $art.Bitmap

    $stage = Join-Path $dist ".gamestage\$basename"
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
    New-Item -ItemType Directory -Force $stage | Out-Null
    Copy-Item -Path (Join-Path $template '*') -Destination $stage -Recurse -Force

    # only ship the referenced, real-art icons
    $iconDir = Join-Path $stage 'www\icons'
    if (Test-Path $iconDir) { Get-ChildItem $iconDir -Recurse -Filter *.png | Remove-Item -Force }
    foreach ($s in 70, 90, 300, 512, 1024) { Save-Resized $master (Join-Path $iconDir "device\experience_$s.png") $s }
    Save-Resized $master (Join-Path $iconDir 'device_sm.png') 16
    Save-Resized $master (Join-Path $iconDir 'device_lg.png') 32
    $master.Dispose()

    # rewrite driver.xml
    $xmlPath = Join-Path $stage 'driver.xml'
    [xml]$xml = Get-Content $xmlPath -Raw
    $dd = $xml.devicedata
    $dd.name = "$Name (Steam)"
    $dd.model = "$Name"
    $dd.version = ([int]$dd.version + 1).ToString()
    $now = Get-Date -Format 'MM/dd/yyyy HH:mm'
    $dd.created = $now; $dd.modified = $now
    foreach ($p in $dd.config.properties.property) {
        if ($p.name -eq 'Game Name') { $p.default = "$Name" }
        elseif ($p.name -eq 'Steam App ID or URI') { $p.default = "$AppId" }
    }
    foreach ($icon in $dd.capabilities.navigator_display_option.display_icons.Icon) {
        $icon.'#text' = $icon.'#text'.Replace('steam-game-miniapp', $basename)
    }
    $xml.Save($xmlPath)

    $out = Join-Path $dist "$basename.c4z"
    if (Test-Path $out) { Remove-Item $out -Force }
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $out
    Remove-Item (Split-Path $stage) -Recurse -Force  # clean .gamestage
    return $art.Source
}
