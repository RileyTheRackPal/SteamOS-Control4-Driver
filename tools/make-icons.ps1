# Generates placeholder PNG icons for both drivers (Windows-only; uses System.Drawing).
# Installers will typically replace the mini-app icons with game art.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$root = Split-Path $PSScriptRoot -Parent

function New-Icon([string]$Path, [int]$Size, [string]$BgHex, [string]$FgHex) {
    $bmp = New-Object System.Drawing.Bitmap($Size, $Size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)
    $bg = [System.Drawing.ColorTranslator]::FromHtml($BgHex)
    $fg = [System.Drawing.ColorTranslator]::FromHtml($FgHex)
    $bgBrush = New-Object System.Drawing.SolidBrush($bg)
    $fgBrush = New-Object System.Drawing.SolidBrush($fg)
    # Rounded-square background
    $m = [Math]::Max(1, [int]($Size * 0.02))
    $r = [Math]::Max(2, [int]($Size * 0.22))
    $rect = New-Object System.Drawing.Rectangle($m, $m, ($Size - 2 * $m), ($Size - 2 * $m))
    $gp = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $r * 2
    $gp.AddArc($rect.X, $rect.Y, $d, $d, 180, 90)
    $gp.AddArc($rect.Right - $d, $rect.Y, $d, $d, 270, 90)
    $gp.AddArc($rect.Right - $d, $rect.Bottom - $d, $d, $d, 0, 90)
    $gp.AddArc($rect.X, $rect.Bottom - $d, $d, $d, 90, 90)
    $gp.CloseFigure()
    $g.FillPath($bgBrush, $gp)
    # Steam-ish piston motif: big ring lower-right, small filled dot upper-left, connecting bar
    $pen = New-Object System.Drawing.Pen($fg, [Math]::Max(1.5, $Size * 0.07))
    $bigD = $Size * 0.34; $bigX = $Size * 0.48; $bigY = $Size * 0.44
    $g.DrawEllipse($pen, [single]$bigX, [single]$bigY, [single]$bigD, [single]$bigD)
    $smD = $Size * 0.16; $smX = $Size * 0.22; $smY = $Size * 0.24
    $g.FillEllipse($fgBrush, [single]$smX, [single]$smY, [single]$smD, [single]$smD)
    $g.DrawLine($pen, [single]($smX + $smD * 0.7), [single]($smY + $smD * 0.7), [single]($bigX + $bigD * 0.22), [single]($bigY + $bigD * 0.22))
    $g.Dispose()
    New-Item -ItemType Directory -Force (Split-Path $Path) | Out-Null
    $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-Host "Wrote $Path"
}

# Main driver: Steam dark navy w/ white motif
$main = Join-Path $root 'steam-machine'
New-Icon (Join-Path $main 'images\icons\device_sm.png') 16  '#171a21' '#c7d5e0'
New-Icon (Join-Path $main 'images\icons\device_lg.png') 32  '#171a21' '#c7d5e0'
foreach ($s in 16, 32, 70, 90, 300, 512, 1024) {
    New-Icon (Join-Path $main "www\icons\device_$s.png") $s '#171a21' '#c7d5e0'
}

# Mini-app template: Steam green w/ white motif (placeholder for game art)
$mini = Join-Path $root 'steam-game-miniapp'
New-Icon (Join-Path $mini 'images\icons\device_sm.png') 16  '#4c6b22' '#e5f0d8'
New-Icon (Join-Path $mini 'images\icons\device_lg.png') 32  '#4c6b22' '#e5f0d8'
foreach ($s in 16, 32, 70, 90, 300, 512, 1024) {
    New-Icon (Join-Path $mini "www\icons\device_$s.png") $s '#4c6b22' '#e5f0d8'
}
