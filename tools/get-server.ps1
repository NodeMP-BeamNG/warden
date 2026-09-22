# Downloads the published Node-Server the gate tests run against into
# .server/ (ignored by git), verifies its sha256 and unpacks it.
#
#   powershell -ExecutionPolicy Bypass -File tools\get-server.ps1 [-Version 1.4.1]
param([string]$Version = "1.4.1")
$ErrorActionPreference = "Stop"

$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$dir = Join-Path $root ".server"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$asset = "Node-Server-$Version-windows-x64.zip"
$base = "https://github.com/NodeMP-BeamNG/releases/releases/download/server-v$Version"

Push-Location $dir
try {
    if (-not (Test-Path $asset)) {
        Invoke-WebRequest -Uri "$base/$asset" -OutFile $asset -UseBasicParsing
        Invoke-WebRequest -Uri "$base/$asset.sha256" -OutFile "$asset.sha256" -UseBasicParsing
    }
    $expected = ((Get-Content "$asset.sha256") -split '\s+')[0].ToLower()
    $actual = (Get-FileHash -Algorithm SHA256 $asset).Hash.ToLower()
    if ($expected -ne $actual) { throw "sha256 mismatch for $asset`nexpected $expected`nactual   $actual" }
    Expand-Archive -Force $asset -DestinationPath .
    $exe = Get-ChildItem -Recurse -Filter "Node-Server.exe" | Select-Object -First 1
    if (-not $exe) { throw "no Node-Server.exe in $asset" }
    Write-Output "Node-Server $Version verified: $($exe.FullName)"
} finally {
    Pop-Location
}
