<#
.SYNOPSIS
  Generate a per-game Steam mini-driver .c4z with the game's real box art baked in
  as the Navigator icons, from just a Steam AppID.

.DESCRIPTION
  Control4 Navigator experience icons are static and bound to the driver TYPE, so
  distinct per-game art requires a distinct .c4z per game (the um_netflix model).
  This tool clones the steam-game-miniapp template, downloads the game's capsule
  art from Steam's public CDN, center-crops/pads it to the square icon ladder, and
  packages dist/steam-game-<appid>.c4z with the AppID + name pre-filled.

.EXAMPLE
  pwsh tools/make-game-driver.ps1 -AppId 620
  pwsh tools/make-game-driver.ps1 -AppId 292030 -Name "The Witcher 3" -Fit pad
#>
param(
    [Parameter(Mandatory)][ValidatePattern('^\d+$')][string]$AppId,
    [string]$Name,
    [ValidateSet('crop', 'pad')][string]$Fit = 'crop'
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$root = Split-Path $PSScriptRoot -Parent
$template = Join-Path $root 'steam-game-miniapp'
$dist = Join-Path $root 'dist'
$basename = "steam-game-$AppId"
New-Item -ItemType Directory -Force $dist | Out-Null

# --- 1. Resolve the game name (Steam storefront API) if not supplied ---------
if (-not $Name) {
    try {
        $api = Invoke-RestMethod -Uri "https://store.steampowered.com/api/appdetails?appids=$AppId&l=en&cc=us" -TimeoutSec 20
        if ($api.$AppId.success -and $api.$AppId.data.name) {
            $Name = $api.$AppId.data.name
        }
    } catch { Write-Warning "appdetails lookup failed: $($_.Exception.Message)" }
    if (-not $Name) { $Name = "Steam Game $AppId" }
}
Write-Host "Game: $Name (AppID $AppId)"

# --- 2. Download the best available art (fallback chain) ----------------------
$cdn = "https://cdn.cloudflare.steamstatic.com/steam/apps/$AppId"
$candidates = @(
    "$cdn/library_600x900_2x.jpg",   # 600x900 portrait (best)
    "$cdn/library_600x900.jpg",      # 300x450 portrait (half-res)
    "$cdn/capsule_616x353.jpg",      # 616x353 landscape
    "$cdn/header.jpg",               # 460x215 landscape (near-universal)
    "$cdn/capsule_231x87.jpg"        # tiny last resort
)
$srcImg = $null; $usedUrl = $null
foreach ($url in $candidates) {
    try {
        $resp = Invoke-WebRequest -Uri $url -TimeoutSec 20
        if ($resp.StatusCode -eq 200 -and $resp.Content.Length -gt 0) {
            $ms = New-Object System.IO.MemoryStream (, $resp.Content)
            $srcImg = [System.Drawing.Image]::FromStream($ms)
            $usedUrl = $url
            break
        }
    } catch { } # 404 etc. -> try next
}
if (-not $srcImg) { throw "No art found for AppID $AppId (tried the full fallback chain)." }
Write-Host "Art: $usedUrl ($($srcImg.Width)x$($srcImg.Height)), fit=$Fit"

# --- 3. Square the source (center-crop or pad) -------------------------------
function New-Square([System.Drawing.Image]$img, [int]$size, [string]$mode) {
    $bmp = New-Object System.Drawing.Bitmap($size, $size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = 'HighQualityBicubic'
    $g.PixelOffsetMode = 'HighQuality'
    $g.Clear([System.Drawing.Color]::FromArgb(255, 23, 26, 33))  # Steam navy backdrop
    if ($mode -eq 'crop') {
        # center-crop the source to a square, then scale to fill the tile
        $side = [Math]::Min($img.Width, $img.Height)
        $sx = [int](($img.Width - $side) / 2)
        $sy = [int](($img.Height - $side) / 2)
        $srcRect = New-Object System.Drawing.Rectangle($sx, $sy, $side, $side)
        $dstRect = New-Object System.Drawing.Rectangle(0, 0, $size, $size)
        $g.DrawImage($img, $dstRect, $srcRect, [System.Drawing.GraphicsUnit]::Pixel)
    } else {
        # pad/letterbox: scale the whole image to fit, centered
        $scale = [Math]::Min($size / $img.Width, $size / $img.Height)
        $w = [int]($img.Width * $scale); $h = [int]($img.Height * $scale)
        $x = [int](($size - $w) / 2); $y = [int](($size - $h) / 2)
        $g.DrawImage($img, $x, $y, $w, $h)
    }
    $g.Dispose()
    return $bmp
}

# --- 4. Stage a clone of the template ----------------------------------------
$stage = Join-Path $dist ".gamestage\$basename"
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force $stage | Out-Null
Copy-Item -Path (Join-Path $template '*') -Destination $stage -Recurse -Force

# write the square icon ladder (experience + list icons). Clear any template
# placeholder PNGs first so only the referenced, real-art icons ship.
$iconDir = Join-Path $stage 'www\icons'
if (Test-Path $iconDir) { Get-ChildItem $iconDir -Recurse -Filter *.png | Remove-Item -Force }
$devDir = Join-Path $iconDir 'device'
New-Item -ItemType Directory -Force $devDir | Out-Null
foreach ($s in 70, 90, 300, 512, 1024) {
    $b = New-Square $srcImg $s $Fit
    $b.Save((Join-Path $devDir "experience_$s.png"), [System.Drawing.Imaging.ImageFormat]::Png)
    $b.Dispose()
}
foreach ($pair in @(@{n = 'device_sm.png'; s = 16 }, @{n = 'device_lg.png'; s = 32 })) {
    $b = New-Square $srcImg $pair.s $Fit
    $b.Save((Join-Path $iconDir $pair.n), [System.Drawing.Imaging.ImageFormat]::Png)
    $b.Dispose()
}
$srcImg.Dispose()

# --- 5. Rewrite driver.xml: name/model, icon basenames, pre-filled props -----
$xmlPath = Join-Path $stage 'driver.xml'
[xml]$xml = Get-Content $xmlPath -Raw
$dd = $xml.devicedata
$dd.name = "$Name (Steam)"
$dd.model = "$Name"
$dd.version = ([int]$dd.version + 1).ToString()
$now = Get-Date -Format 'MM/dd/yyyy HH:mm'
$dd.created = $now; $dd.modified = $now

# pre-fill the two editable properties so the driver works on add
foreach ($p in $dd.config.properties.property) {
    if ($p.name -eq 'Game Name') { $p.default = "$Name" }
    elseif ($p.name -eq 'Steam App ID or URI') { $p.default = "$AppId" }
}

# the navigator_display_option Icon paths reference controller://driver/<basename>/...
# and MUST match the .c4z filename
foreach ($icon in $dd.capabilities.navigator_display_option.display_icons.Icon) {
    $icon.'#text' = $icon.'#text'.Replace('steam-game-miniapp', $basename)
}
$xml.Save($xmlPath)

# --- 6. Package the .c4z (contents at zip root) ------------------------------
$out = Join-Path $dist "$basename.c4z"
if (Test-Path $out) { Remove-Item $out -Force }
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $out
Remove-Item (Join-Path $dist '.gamestage') -Recurse -Force
Write-Host "Packaged $out"
Write-Host "Install via Composer > Driver > Add or Update Driver, then bind its 'Steam Game' connection to a free Game App slot on the Steam Machine driver."
