#!/usr/bin/env bash
# Downloads the published Node-Server the gate tests run against into
# .server/ (ignored by git), verifies its sha256 and unpacks it.
#
#   tools/get-server.sh [1.4.1]
set -euo pipefail

version="${1:-1.4.1}"
root="$(cd "$(dirname "$0")/.." && pwd)"
dir="$root/.server"
mkdir -p "$dir"
cd "$dir"
asset="Node-Server-$version-linux-x64.tar.gz"
base="https://github.com/NodeMP-BeamNG/releases/releases/download/server-v$version"
if [[ ! -f "$asset" ]]; then
  curl -fsSL --retry 3 -o "$asset" "$base/$asset"
  curl -fsSL --retry 3 -o "$asset.sha256" "$base/$asset.sha256"
fi
sha256sum -c "$asset.sha256"
tar -xzf "$asset"
chmod +x Node-Server
./Node-Server --version
echo "Node-Server $version verified: $dir/Node-Server"
