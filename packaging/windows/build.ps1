# Builds Lurker for Windows, with mpv and streamlink beside it, and its installer.
# Run from a "x64 Native Tools" prompt (for lib.exe and dumpbin.exe), with Odin on
# the PATH. Inno Setup's ISCC.exe makes the installer; without it, only
# build\windows\dist is made.
#
#   powershell -ExecutionPolicy Bypass -File packaging\windows\build.ps1 [-Version 0.1.0]

param(
	[string]$Version = "dev",
	[switch]$SkipInstaller
)

$ErrorActionPreference = "Stop"
$root = Resolve-Path "$PSScriptRoot\..\.."
$out = "$root\build\windows"
$deps = "$out\deps"
$dist = "$out\dist"

# libmpv from mpv-winbuild, and streamlink's portable build (with its own Python).
$mpvUrl = "https://github.com/zhongfly/mpv-winbuild/releases/download/2026-10-23-3aecc359bb/mpv-dev-x86_64-20261023-git-3aecc359bb.7z"
$mpvSha = "a25d0b6461dcd4fc6d7d1b1b7929a71ccf18fad0593fff1d10d65f83c532df27"
$streamlinkUrl = "https://github.com/streamlink/windows-builds/releases/download/8.6.2-2/streamlink-8.6.2-2-py314-x86_64.zip"
$streamlinkSha = "12e0c8e43b736f75ec67e44cd375ee05be301d7f25a5e2ec1aaa1f81c67ff2b3"

function Get-Checked($url, $sha, $file) {
	if (-not (Test-Path $file) -or (Get-FileHash $file -Algorithm SHA256).Hash -ne $sha) {
		Write-Host "Downloading $url"
		Invoke-WebRequest $url -OutFile $file
	}
	if ((Get-FileHash $file -Algorithm SHA256).Hash -ne $sha) {
		throw "$file doesn't match its checksum"
	}
}

New-Item -ItemType Directory -Force $deps | Out-Null

# libmpv: the DLL, and an import library the MSVC linker can use, made from the
# DLL's exports (the package's libmpv.dll.a is MinGW's format).
Get-Checked $mpvUrl $mpvSha "$deps\mpv-dev.7z"
if (-not (Test-Path "$deps\mpv\libmpv-2.dll")) {
	7z x "$deps\mpv-dev.7z" "-o$deps\mpv" -y | Out-Null
}
$exports = dumpbin /exports "$deps\mpv\libmpv-2.dll" | ForEach-Object {
	if ($_ -match '^\s+\d+\s+[0-9A-F]+\s+[0-9A-F]+\s+(mpv_\w+)') { $Matches[1] }
}
"LIBRARY libmpv-2`nEXPORTS`n" + ($exports -join "`n") | Set-Content "$deps\mpv\mpv.def"
lib /nologo /def:"$deps\mpv\mpv.def" /machine:x64 /out:"$deps\mpv\mpv.lib" | Out-Null

# streamlink, unpacked to streamlink\ beside lurker.exe, where Lurker looks for it.
Get-Checked $streamlinkUrl $streamlinkSha "$deps\streamlink.zip"
if (-not (Test-Path "$deps\streamlink\bin\streamlinkw.exe")) {
	Remove-Item -Recurse -Force "$deps\streamlink-unpacked" -ErrorAction SilentlyContinue
	Expand-Archive "$deps\streamlink.zip" "$deps\streamlink-unpacked"
	Move-Item (Get-ChildItem "$deps\streamlink-unpacked" -Directory)[0].FullName "$deps\streamlink"
}

# Lurker itself: a windowed program, with its icon.
Remove-Item -Recurse -Force $dist -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $dist | Out-Null
Push-Location $root
try {
	odin build src "-out:$dist\lurker.exe" -o:speed -no-bounds-check -disable-assert -subsystem:windows `
		"-resource:packaging\windows\lurker.rc" "-extra-linker-flags:/LIBPATH:$deps\mpv"
	if ($LASTEXITCODE -ne 0) { throw "odin build failed" }
} finally {
	Pop-Location
}

# The DLLs it loads: SDL3 and SDL3_image (with its image formats) from Odin's
# vendor folder, and libmpv.
$odinRoot = (odin root).Trim()
Copy-Item "$odinRoot\vendor\sdl3\SDL3.dll" $dist
Copy-Item "$odinRoot\vendor\sdl3\image\*.dll" $dist
Copy-Item "$deps\mpv\libmpv-2.dll" $dist
Copy-Item -Recurse "$deps\streamlink" "$dist\streamlink"
Copy-Item "$root\LICENSE" "$dist\LICENSE.txt"

if ($SkipInstaller) { exit 0 }
$iscc = Get-Command ISCC.exe -ErrorAction SilentlyContinue
if (-not $iscc) { $iscc = Get-Item "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe" -ErrorAction SilentlyContinue }
if (-not $iscc) {
	Write-Host "Inno Setup isn't installed: skipping the installer. The app is in $dist"
	exit 0
}
& $iscc.Source /Qp "/DAppVersion=$Version" "/DDist=$dist" "/O$out" "$root\packaging\windows\lurker.iss"
if ($LASTEXITCODE -ne 0) { throw "ISCC failed" }
