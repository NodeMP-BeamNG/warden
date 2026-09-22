# Packs the release archive on Windows: dist\warden-<version>.zip (+ .sha256),
# the same layout as tools/pack.sh:
#   resources/warden/      the server resource with its client/ half -- the panel the
#                          server streams to every player (without data/ and any dev/ probes)
#   README.md README.ru.md
#   docs/                  the hoster documentation (dev.md excluded)
# The version is read from resources/warden/resource.toml. One archive, unzipped
# at the server root, is the whole install. client/warden/lang.lua must be
# current (lua tools/lang-gen.lua --check) -- the pack refuses a stale one.
#
#   powershell -ExecutionPolicy Bypass -File tools\pack.ps1
$ErrorActionPreference = "Stop"

$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$manifest = Join-Path $root "resources\warden\resource.toml"
$versionLine = Get-Content $manifest | Where-Object { $_ -match '^version\s*=\s*"([^"]+)"' } | Select-Object -First 1
if (-not $versionLine) { throw "pack: no version = ""x.y.z"" in $manifest" }
$version = [regex]::Match($versionLine, '^version\s*=\s*"([^"]+)"').Groups[1].Value

# the panel's dictionary is generated from lang/*.json: never ship a stale one
$lua = Get-Command lua, lua5.4 -ErrorAction SilentlyContinue | Select-Object -First 1
if ($lua) {
    & $lua.Source (Join-Path $root "tools\lang-gen.lua") --check
    if ($LASTEXITCODE -ne 0) { throw "pack: client/warden/lang.lua is stale; run lua tools/lang-gen.lua" }
} else {
    Write-Warning "pack: no lua on PATH; client/warden/lang.lua not checked against lang/*.json"
}

$out = Join-Path $root "dist"
New-Item -ItemType Directory -Force -Path $out | Out-Null
$zipPath = Join-Path $out "warden-$version.zip"
Remove-Item -Force -ErrorAction SilentlyContinue $zipPath, "$zipPath.sha256"

$stage = Join-Path ([IO.Path]::GetTempPath()) ("warden-pack-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path (Join-Path $stage "resources") | Out-Null
try {
    Copy-Item -Recurse (Join-Path $root "resources\warden") (Join-Path $stage "resources\warden")
    foreach ($drop in @("data", "server\dev", ".obfcache", "__pycache__")) {
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue (Join-Path $stage "resources\warden\$drop")
    }
    Copy-Item (Join-Path $root "README.md") (Join-Path $stage "README.md")
    Copy-Item (Join-Path $root "README.ru.md") (Join-Path $stage "README.ru.md")
    $docs = Join-Path $root "docs"
    if (Test-Path $docs) {
        Copy-Item -Recurse $docs (Join-Path $stage "docs")
        Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $stage "docs\dev.md")
    }

    # one entry per file, forward slashes, ordinal order, no directory entries
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $files = @(Get-ChildItem -Recurse -File -Force $stage | ForEach-Object { $_.FullName })
    [Array]::Sort($files, [StringComparer]::Ordinal)
    $zip = [IO.Compression.ZipFile]::Open($zipPath, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($full in $files) {
            $rel = $full.Substring($stage.Length).TrimStart('\', '/').Replace('\', '/')
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $full, $rel,
                [IO.Compression.CompressionLevel]::Optimal) | Out-Null
        }
    } finally {
        $zip.Dispose()
    }
} finally {
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $stage
}

$zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
try { $names = @($zip.Entries | ForEach-Object { $_.FullName }) } finally { $zip.Dispose() }
$bad = @($names | Where-Object { $_ -match '\\' -or $_ -match '/$' -or $_ -eq '' })
if ($bad.Count -gt 0) {
    Remove-Item -Force -ErrorAction SilentlyContinue $zipPath
    throw ("pack: bad zip entries: " + ($bad -join ", "))
}
if ($names.Count -ne $files.Count) { throw "pack: $($names.Count) entries written for $($files.Count) files" }

$hash = (Get-FileHash -Algorithm SHA256 $zipPath).Hash.ToLower()
[IO.File]::WriteAllText("$zipPath.sha256", "$hash  warden-$version.zip`n")
Write-Output $zipPath
