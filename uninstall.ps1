<#
.SYNOPSIS
  Removes everything install.ps1 added (listed in NarutoStormRemaster.install.txt) and restores backups.
#>
param([string]$GameDir)

$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$ManifestName = 'NarutoStormRemaster.install.txt'

if (-not $GameDir) {
	foreach ($c in @($Here, (Split-Path -Parent $Here))) { if (Test-Path (Join-Path $c $ManifestName)) { $GameDir = $c; break } }
}
if (-not $GameDir) {
	$steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
	if ($steam) {
		$libs = @($steam)
		$vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
		if (Test-Path $vdf) { $libs += (Select-String -Path $vdf -Pattern '"path"\s+"([^"]+)"' -AllMatches).Matches | ForEach-Object { $_.Groups[1].Value -replace '\\\\', '\' } }
		foreach ($lib in ($libs | Select-Object -Unique)) {
			$m = Get-ChildItem (Join-Path $lib 'steamapps\common') -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path (Join-Path $_.FullName $ManifestName) } | Select-Object -First 1
			if ($m) { $GameDir = $m.FullName; break }
		}
	}
}
if (-not $GameDir -or -not (Test-Path (Join-Path $GameDir $ManifestName))) {
	throw "No installation found. Re-run with -GameDir `"<game folder>`"."
}
if (Get-Process -Name 'NSUNS1' -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($GameDir, 'OrdinalIgnoreCase') }) { throw "Close the game before uninstalling." }

$manifestPath = Join-Path $GameDir $ManifestName
$entries = Get-Content $manifestPath | Where-Object { $_ }
# Remove our files first, then put backups back (a backup can replace a file we just removed).
$rows = $entries | ForEach-Object { , ($_ -split '\|') } # [kind, path, backup?]
foreach ($r in $rows) {
	if ($r[0] -ne 'file') { continue }
	$path = Join-Path $GameDir $r[1]
	if (Test-Path $path) { Remove-Item $path -Force }
}
foreach ($r in $rows) {
	if ($r[0] -ne 'backup') { continue }
	$bak = Join-Path $GameDir $r[2]
	if (Test-Path $bak) { Move-Item $bak (Join-Path $GameDir $r[1]) -Force }
}
# Directories last, and only if now empty (never deletes your other shaders/presets).
foreach ($r in $rows) {
	if ($r[0] -ne 'dir') { continue }
	$path = Join-Path $GameDir $r[1]
	if ((Test-Path $path) -and -not (Get-ChildItem $path -Force)) { Remove-Item $path -Force }
}
# ReShade's own log, only if we installed ReShade.
if ($entries -match '^file\|(dxgi|d3d11)\.dll$') { Remove-Item (Join-Path $GameDir 'ReShade.log') -Force -ErrorAction SilentlyContinue }
Remove-Item $manifestPath -Force
Write-Host "Naruto Storm Remaster removed from $GameDir. The game is back to its original look."
