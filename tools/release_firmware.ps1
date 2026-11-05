# Build Gympath_Track and publish it for over-the-air updates.
#
#   1. Bump FW_VERSION in firmware/Gympath_Track/Gympath_Track.ino
#   2. Run:  powershell -File tools\release_firmware.ps1 -Notes "what changed"
#   3. Commit + push the website repo -> app users see the update
#
# Writes website/firmware/gympath_track-<version>.bin and manifest.json.
param([string]$Notes = "")

$ErrorActionPreference = "Stop"
$root   = Split-Path $PSScriptRoot -Parent
$sketch = Join-Path $root "firmware\Gympath_Track"
$dst    = Join-Path $root "website\firmware"
$cli    = "$env:LOCALAPPDATA\Programs\Arduino IDE\resources\app\lib\backend\resources\arduino-cli.exe"

$src = Get-Content (Join-Path $sketch "Gympath_Track.ino") -Raw
$m = [regex]::Match($src, '#define\s+FW_VERSION\s+"([^"]+)"')
if (-not $m.Success) { throw "FW_VERSION not found in Gympath_Track.ino" }
$version = $m.Groups[1].Value

$manifestPath = Join-Path $dst "manifest.json"
if (Test-Path $manifestPath) {
  $old = (Get-Content $manifestPath -Raw | ConvertFrom-Json).version
  if ($old -eq $version) { throw "FW_VERSION is still $version - bump it before releasing" }
}

$build = Join-Path $env:TEMP "gp_release_build"
Remove-Item $build -Recurse -Force -ErrorAction SilentlyContinue
& $cli compile --fqbn esp32:esp32:esp32s3 --output-dir $build $sketch
if ($LASTEXITCODE -ne 0) { throw "compile failed" }

New-Item -ItemType Directory -Force $dst | Out-Null
$name = "gympath_track-$version.bin"
$bin  = Join-Path $dst $name
Copy-Item (Join-Path $build "Gympath_Track.ino.bin") $bin -Force

$manifest = [ordered]@{
  version       = $version
  url           = "https://tutu-cjay.github.io/firmware/$name"
  size          = (Get-Item $bin).Length
  md5           = (Get-FileHash $bin -Algorithm MD5).Hash.ToLower()
  notes         = $Notes
  minAppVersion = "1.0.0"
}
$manifest | ConvertTo-Json | Set-Content $manifestPath -Encoding ascii
Write-Host "Released $version -> $bin"
Get-Content $manifestPath
