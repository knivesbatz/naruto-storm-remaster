<#
  Builds dist\NarutoStormRemaster-<version>.zip (no ReShade binaries are included).
  Usage: powershell -ExecutionPolicy Bypass -File tools\build_release.ps1 -Version 1.0.0
#>
param([string]$Version = '1.0.0')
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

& python -I (Join-Path $repo 'tools\check_presets.py')
if ($LASTEXITCODE) { throw 'Preset check failed.' }

$stage = Join-Path $repo "dist\NarutoStormRemaster-$Version"
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $stage | Out-Null
foreach ($f in 'install.ps1', 'uninstall.ps1', 'Install.bat', 'Uninstall.bat', 'README.md', 'LICENSE') { Copy-Item (Join-Path $repo $f) $stage }
Copy-Item (Join-Path $repo 'src') $stage -Recurse

$zip = "$stage.zip"
Remove-Item $zip -Force -ErrorAction SilentlyContinue
Compress-Archive -Path "$stage\*" -DestinationPath $zip
Remove-Item $stage -Recurse -Force
Write-Host "Built $zip ($([math]::Round((Get-Item $zip).Length / 1KB)) KB)"
