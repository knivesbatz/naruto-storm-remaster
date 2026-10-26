<#
.SYNOPSIS
  Installs the Naruto Storm Remaster ReShade preset into NARUTO: Ultimate Ninja STORM (Steam, app 495140).

.DESCRIPTION
  - Finds the game folder (argument, the folder this script sits in or its parent, or the Steam library).
  - Uses an existing ReShade install if there is one; otherwise extracts ReShade64.dll from an
    official ReShade_Setup_*.exe you downloaded from https://reshade.me (this package does not ship ReShade).
  - Copies shaders and presets, writes ReShade.ini, and records every change in
    NarutoStormRemaster.install.txt so uninstall.ps1 can undo it exactly. No game files are modified.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File install.ps1
  powershell -ExecutionPolicy Bypass -File install.ps1 -GameDir "D:\SteamLibrary\steamapps\common\QWANT" -ReShadeSetup "C:\Downloads\ReShade_Setup_6.7.3.exe"
#>
param([string]$GameDir, [string]$ReShadeSetup)

$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Src = Join-Path $Here 'src'
$Exe = 'NSUNS1.exe'
$AppId = '495140'
$ManifestName = 'NarutoStormRemaster.install.txt'
$Marker = '; NarutoStormRemaster'

function Write-Step($msg) { Write-Host "  - $msg" }

function Find-SteamGameDir {
	$steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
	if (-not $steam) { return $null }
	$libs = @($steam)
	$vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
	if (Test-Path $vdf) {
		$libs += (Select-String -Path $vdf -Pattern '"path"\s+"([^"]+)"' -AllMatches).Matches | ForEach-Object { $_.Groups[1].Value -replace '\\\\', '\' }
	}
	foreach ($lib in ($libs | Select-Object -Unique)) {
		$acf = Join-Path $lib "steamapps\appmanifest_$AppId.acf"
		if (-not (Test-Path $acf)) { continue }
		$m = Select-String -Path $acf -Pattern '"installdir"\s+"([^"]+)"'
		if ($m) {
			$dir = Join-Path $lib ('steamapps\common\' + $m.Matches[0].Groups[1].Value)
			if (Test-Path (Join-Path $dir $Exe)) { return $dir }
		}
	}
	return $null
}

function Test-IsReShade($path) {
	(Test-Path $path) -and ((Get-Item $path).VersionInfo.ProductName -match 'ReShade')
}

# ReShade_Setup_*.exe is a launcher with a zip appended; locate the zip via its end-of-central-directory record.
function Expand-ReShadeDll($setup, $dest) {
	Add-Type -AssemblyName System.IO.Compression
	$b = [IO.File]::ReadAllBytes($setup)
	$e = $b.Length - 22
	while ($e -ge 0 -and -not ($b[$e] -eq 0x50 -and $b[$e + 1] -eq 0x4B -and $b[$e + 2] -eq 5 -and $b[$e + 3] -eq 6)) { $e-- }
	if ($e -lt 0) { throw "$setup does not look like a ReShade setup file." }
	$start = $e - [BitConverter]::ToUInt32($b, $e + 12) - [BitConverter]::ToUInt32($b, $e + 16)
	$ms = New-Object IO.MemoryStream($b, [int]$start, [int]($b.Length - $start))
	$zip = New-Object IO.Compression.ZipArchive($ms)
	try {
		$entry = $zip.GetEntry('ReShade64.dll')
		if (-not $entry) { throw "ReShade64.dll not found inside $setup." }
		$in = $entry.Open()
		$out = [IO.File]::Create($dest)
		try { $in.CopyTo($out) } finally { $out.Dispose(); $in.Dispose() }
	} finally { $zip.Dispose() }
}

Write-Host "Naruto Storm Remaster - installer"

# 1. Game folder
if (-not $GameDir) {
	foreach ($c in @($Here, (Split-Path -Parent $Here))) { if (Test-Path (Join-Path $c $Exe)) { $GameDir = $c; break } }
}
if (-not $GameDir) { $GameDir = Find-SteamGameDir }
if (-not $GameDir -or -not (Test-Path (Join-Path $GameDir $Exe))) {
	throw "Could not find $Exe. Re-run with -GameDir `"<folder that contains $Exe>`"."
}
$GameDir = (Resolve-Path $GameDir).Path
Write-Step "Game folder: $GameDir"

$manifestPath = Join-Path $GameDir $ManifestName
if (Test-Path $manifestPath) { throw "Already installed ($ManifestName exists). Run uninstall.ps1 first to reinstall." }
$manifest = New-Object System.Collections.Generic.List[string]

if (Get-Process -Name 'NSUNS1' -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($GameDir, 'OrdinalIgnoreCase') }) { throw "Close the game before installing." }

# 2. ReShade
$dxgi = Join-Path $GameDir 'dxgi.dll'
$d3d11 = Join-Path $GameDir 'd3d11.dll'
if ((Test-IsReShade $dxgi) -or (Test-IsReShade $d3d11)) {
	Write-Step 'Existing ReShade found - keeping it.'
} else {
	if (-not $ReShadeSetup) {
		$ReShadeSetup = Get-ChildItem -Path @($Here, (Join-Path $env:USERPROFILE 'Downloads')) -Filter 'ReShade_Setup_*.exe' -ErrorAction SilentlyContinue |
			Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
	}
	if (-not $ReShadeSetup -or -not (Test-Path $ReShadeSetup)) {
		throw "ReShade is not installed. Download ReShade from https://reshade.me, put ReShade_Setup_x.y.z.exe in your Downloads folder (or next to this script), and run the installer again."
	}
	# Another mod already uses dxgi.dll: load ReShade as d3d11.dll instead of touching it.
	$target = if (Test-Path $dxgi) { $d3d11 } else { $dxgi }
	if (Test-Path $target) { throw "$target exists and is not ReShade. Remove it or install ReShade manually." }
	Expand-ReShadeDll $ReShadeSetup $target
	$manifest.Add("file|" + (Split-Path -Leaf $target))
	Write-Step "Installed ReShade from $(Split-Path -Leaf $ReShadeSetup) as $(Split-Path -Leaf $target)"
}

# 3. Shaders and presets (our own subfolders only)
foreach ($rel in @('reshade-shaders\Shaders\NarutoStorm', 'reshade-presets\NarutoStorm')) {
	$dst = Join-Path $GameDir $rel
	New-Item -ItemType Directory -Force -Path $dst | Out-Null
	Get-ChildItem (Join-Path $Src $rel) -File | ForEach-Object {
		Copy-Item $_.FullName (Join-Path $dst $_.Name) -Force
		$manifest.Add("file|$rel\$($_.Name)")
	}
	$manifest.Add("dir|$rel")
}
Write-Step 'Copied the shader and the Low/Medium/High/Ultra/Manga/Vanilla presets.'

# 4. ReShade.ini (back up a foreign one)
$ini = Join-Path $GameDir 'ReShade.ini'
if (Test-Path $ini) {
	$bak = "$ini.ns-backup"
	Copy-Item $ini $bak -Force
	$manifest.Add("backup|ReShade.ini|ReShade.ini.ns-backup")
	Write-Step 'Backed up your existing ReShade.ini to ReShade.ini.ns-backup'
}
Copy-Item (Join-Path $Src 'ReShade.ini') $ini -Force
$manifest.Add('file|ReShade.ini')

$manifest.Add('dir|reshade-shaders\Shaders')
$manifest.Add('dir|reshade-shaders')
$manifest.Add('dir|reshade-presets')
Set-Content -Path $manifestPath -Value $manifest -Encoding UTF8
Write-Host ''
Write-Host 'Done. Start the game: High preset is active.'
Write-Host '  Home = ReShade menu   End = effects on/off   PageUp/PageDown = switch preset'
