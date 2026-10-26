<#
  Builds dist\NarutoStormRemaster-<version>.zip: a plain ReShade drop-in (presets + reshade-shaders), no ReShade binaries.
  Usage: powershell -ExecutionPolicy Bypass -File tools\build_release.ps1 -Version 1.1.1
#>
param([string]$Version = '1.1.1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

& python -I (Join-Path $repo 'tools\check_presets.py')
if ($LASTEXITCODE) { throw 'Preset check failed.' }

New-Item -ItemType Directory -Force -Path (Join-Path $repo 'dist') | Out-Null
$zip = Join-Path $repo "dist\NarutoStormRemaster-$Version.zip"
Remove-Item $zip -Force -ErrorAction SilentlyContinue
$items = @(Get-ChildItem (Join-Path $repo 'NarutoStorm_*.ini')).FullName + @((Join-Path $repo 'reshade-shaders'), (Join-Path $repo 'README.md'), (Join-Path $repo 'LICENSE'))
Compress-Archive -Path $items -DestinationPath $zip
Write-Host "Built $zip ($([math]::Round((Get-Item $zip).Length / 1KB)) KB)"
