# Packs the release archive on Windows: dist\warden-<version>.zip (+ .sha256),
# the same layout as tools/pack.sh:
#   resources/warden/      the server resource with its client/ half -- the panel the
#                          server streams to every player (without data/ and any dev/ probes)
#   content/warden.zip     the client content zip built here from content/warden/: the
#                          bindable game action "Toggle Warden panel" (the server's content/
#                          folder delivers it to the players through the launcher)
#   LICENSE NOTICE         the licence and the notices (GPL section 4: every copy carries them)
#   README.md README.ru.md CHANGELOG.md
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

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# one entry per file, forward slashes, ordinal order, no directory entries
function New-FlatZip([string]$source, [string]$target) {
    $files = @(Get-ChildItem -Recurse -File -Force $source | ForEach-Object { $_.FullName })
    [Array]::Sort($files, [StringComparer]::Ordinal)
    Remove-Item -Force -ErrorAction SilentlyContinue $target
    $zip = [IO.Compression.ZipFile]::Open($target, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($full in $files) {
            $rel = $full.Substring($source.Length).TrimStart('\', '/').Replace('\', '/')
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $full, $rel,
                [IO.Compression.CompressionLevel]::Optimal) | Out-Null
        }
    } finally {
        $zip.Dispose()
    }
    return $files.Count
}

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
    foreach ($top in @("LICENSE", "NOTICE", "README.md", "README.ru.md", "CHANGELOG.md")) {
        $src = Join-Path $root $top
        if (-not (Test-Path $src)) { throw "pack: $top is missing; the archive must carry it" }
        Copy-Item $src (Join-Path $stage $top)
    }
    $docs = Join-Path $root "docs"
    if (Test-Path $docs) {
        Copy-Item -Recurse $docs (Join-Path $stage "docs")
        Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $stage "docs\dev.md")
    }

    # the client content zip: the game action (content/warden/ -> content/warden.zip)
    $contentSrc = Join-Path $root "content\warden"
    if (-not (Test-Path (Join-Path $contentSrc "lua\ge\extensions\core\input\actions\warden.json"))) {
        throw "pack: content/warden/ carries no input action; the archive must ship content/warden.zip"
    }
    New-Item -ItemType Directory -Path (Join-Path $stage "content") | Out-Null
    $inner = New-FlatZip $contentSrc (Join-Path $stage "content\warden.zip")
    if ($inner -lt 2) { throw "pack: content/warden.zip has $inner file(s); expected the action and the modScript" }

    $files = @(Get-ChildItem -Recurse -File -Force $stage | ForEach-Object { $_.FullName })
    $written = New-FlatZip $stage $zipPath
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
if ($names.Count -ne $files.Count -or $written -ne $files.Count) {
    throw "pack: $($names.Count) entries written for $($files.Count) files"
}
if ($names -notcontains "content/warden.zip") { throw "pack: the archive carries no content/warden.zip" }

$hash = (Get-FileHash -Algorithm SHA256 $zipPath).Hash.ToLower()
[IO.File]::WriteAllText("$zipPath.sha256", "$hash  warden-$version.zip`n")
Write-Output $zipPath
