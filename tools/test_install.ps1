<#
  Round-trip test for install.ps1 / uninstall.ps1 against a fake game folder.
  Usage: powershell -ExecutionPolicy Bypass -File tools\test_install.ps1 -ReShadeSetup <path to ReShade_Setup_*.exe>
#>
param([Parameter(Mandatory = $true)][string]$ReShadeSetup)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$game = Join-Path ([IO.Path]::GetTempPath()) ("ns-remaster-test-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $game | Out-Null
$fails = 0
function Check($cond, $msg) { if ($cond) { Write-Host "ok   $msg" } else { Write-Host "FAIL $msg"; $script:fails++ } }

try {
	Set-Content (Join-Path $game 'NSUNS1.exe') 'fake'
	Set-Content (Join-Path $game 'ReShade.ini') '[GENERAL]' # a pre-existing, foreign ReShade.ini must survive the round trip
	New-Item -ItemType Directory -Path (Join-Path $game 'reshade-shaders\Shaders\Other') | Out-Null
	Set-Content (Join-Path $game 'reshade-shaders\Shaders\Other\Mine.fx') '//'

	& (Join-Path $repo 'install.ps1') -GameDir $game -ReShadeSetup $ReShadeSetup | Out-Null
	Check ((Get-Item (Join-Path $game 'dxgi.dll')).VersionInfo.ProductName -match 'ReShade') 'dxgi.dll is ReShade'
	Check (Test-Path (Join-Path $game 'reshade-shaders\Shaders\NarutoStorm\NS_Remaster.fx')) 'shader installed'
	Check (Test-Path (Join-Path $game 'reshade-presets\NarutoStorm\NarutoStorm_High.ini')) 'presets installed'
	Check ((Get-Content (Join-Path $game 'ReShade.ini') -Raw) -match 'NarutoStorm_High') 'ReShade.ini points at High preset'
	Check ((Get-Content (Join-Path $game 'ReShade.ini.ns-backup') -Raw) -match '^\[GENERAL\]') 'foreign ReShade.ini backed up'

	$threw = $false
	try { & (Join-Path $repo 'install.ps1') -GameDir $game -ReShadeSetup $ReShadeSetup | Out-Null } catch { $threw = $true }
	Check $threw 'second install refuses'

	& (Join-Path $repo 'uninstall.ps1') -GameDir $game | Out-Null
	Check (-not (Test-Path (Join-Path $game 'dxgi.dll'))) 'dxgi.dll removed'
	Check (-not (Test-Path (Join-Path $game 'reshade-shaders\Shaders\NarutoStorm'))) 'our shader folder removed'
	Check (-not (Test-Path (Join-Path $game 'reshade-presets'))) 'preset folder removed'
	Check (Test-Path (Join-Path $game 'reshade-shaders\Shaders\Other\Mine.fx')) "user's other shaders kept"
	Check ((Get-Content (Join-Path $game 'ReShade.ini') -Raw).Trim() -eq '[GENERAL]') 'original ReShade.ini restored'
	Check (-not (Test-Path (Join-Path $game 'NarutoStormRemaster.install.txt'))) 'manifest removed'
	Check (Test-Path (Join-Path $game 'NSUNS1.exe')) 'game files untouched'
} finally {
	Remove-Item $game -Recurse -Force -ErrorAction SilentlyContinue
}
if ($fails) { Write-Host "$fails check(s) failed"; exit 1 } else { Write-Host 'all install checks passed' }
