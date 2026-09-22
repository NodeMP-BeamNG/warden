#!/usr/bin/env bash
# Packs the release archive: dist/warden-<version>.zip (+ .sha256) with
#   resources/warden/      the server resource (without data/ and dev/ probes)
#   README.md README.ru.md
#   docs/                  the hoster documentation (dev.md excluded)
# The version is read from resources/warden/resource.toml. Needs `zip`.
#
#   tools/pack.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
manifest="$root/resources/warden/resource.toml"
version="$(sed -nE 's/^version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$manifest" | head -n1)"
[[ -n "$version" ]] || { echo "pack: no version in $manifest" >&2; exit 1; }

out="$root/dist"
mkdir -p "$out"
zip_path="$out/warden-$version.zip"
rm -f "$zip_path" "$zip_path.sha256"

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/resources"
cp -R "$root/resources/warden" "$stage/resources/warden"
rm -rf "$stage/resources/warden/data" "$stage/resources/warden/server/dev"
find "$stage" -name .obfcache -o -name __pycache__ | xargs -r rm -rf
cp "$root/README.md" "$root/README.ru.md" "$stage/"
if [[ -d "$root/docs" ]]; then
  cp -R "$root/docs" "$stage/docs"
  rm -f "$stage/docs/dev.md"
fi

# one entry per file, no directory entries (-D), stable order
(cd "$stage" && find . -type f | sed 's|^\./||' | LC_ALL=C sort | zip -q -X -D "$zip_path" -@)

if unzip -Z1 "$zip_path" | grep -E '\\|/$' >/dev/null; then
  echo "pack: backslash or directory entry in $zip_path" >&2
  rm -f "$zip_path"
  exit 1
fi
(cd "$out" && sha256sum "warden-$version.zip" > "warden-$version.zip.sha256")
echo "$zip_path"
