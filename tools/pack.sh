#!/usr/bin/env bash
# Packs the release archive: dist/warden-<version>.zip (+ .sha256) with
#   resources/warden/      the server resource with its client/ half -- the panel the
#                          server streams to every player (without data/ and dev/ probes)
#   LICENSE NOTICE         the licence and the notices (GPL section 4: every copy carries them)
#   README.md README.ru.md CHANGELOG.md
#   docs/                  the hoster documentation (dev.md excluded)
# The version is read from resources/warden/resource.toml. One archive, unzipped
# at the server root, is the whole install. Needs `zip`; with `lua`/`lua5.4` on
# PATH the generated client/warden/lang.lua is checked against lang/*.json.
#
#   tools/pack.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
manifest="$root/resources/warden/resource.toml"
version="$(sed -nE 's/^version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$manifest" | head -n1)"
[[ -n "$version" ]] || { echo "pack: no version in $manifest" >&2; exit 1; }

lua_bin="$(command -v lua5.4 || command -v lua || true)"
if [[ -n "$lua_bin" ]]; then
  "$lua_bin" "$root/tools/lang-gen.lua" --check
else
  echo "pack: no lua on PATH; client/warden/lang.lua not checked against lang/*.json" >&2
fi

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
for top in LICENSE NOTICE README.md README.ru.md CHANGELOG.md; do
  [[ -f "$root/$top" ]] || { echo "pack: $top is missing; the archive must carry it" >&2; exit 1; }
  cp "$root/$top" "$stage/$top"
done
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
