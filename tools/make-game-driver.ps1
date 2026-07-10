<#
.SYNOPSIS
  Generate ONE per-game Steam mini-driver .c4z with the game's square icon baked in,
  from a Steam AppID.
.DESCRIPTION
  Control4 Navigator icons are static and bound to the driver TYPE, so per-game art
  means one .c4z per game. Icon source (best square first): the official 256px
  clienticon -> the game's logo on a backdrop -> box-art crop.
.EXAMPLE
  pwsh tools/make-game-driver.ps1 -AppId 620
  pwsh tools/make-game-driver.ps1 -AppId 570 -Style logo
#>
param(
    [Parameter(Mandatory)][ValidatePattern('^\d+$')][string]$AppId,
    [string]$Name,
    [ValidateSet('auto', 'icon', 'logo', 'boxart')][string]$Style = 'auto'
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/steam-driver-lib.ps1"
$root = Split-Path $PSScriptRoot -Parent

if (-not $Name) { $Name = Get-SteamGameName $AppId }
Write-Host "Game: $Name (AppID $AppId)"
$src = New-SteamGameDriver -AppId $AppId -Name $Name -Style $Style -Root $root
Write-Host "Packaged dist/steam-game-$AppId.c4z (icon source: $src)"
Write-Host "Install via Composer > Driver > Add or Update Driver, then bind its 'Steam Game' connection to a free Game App slot on the Steam Machine driver."
