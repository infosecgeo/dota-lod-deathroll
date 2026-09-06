#!/usr/bin/env bash
# ============================================================
# LOD Deathroll - plug-and-play installer (Linux/macOS)
# Copies the addon into your Dota 2 Workshop Tools addons
# folder and installs the local MMR server dependencies.
#
# Usage:
#   ./install.sh "/path/to/dota 2 beta"
# Default: ~/.steam/steam/steamapps/common/dota 2 beta
# ============================================================
set -euo pipefail

DOTA_DIR="${1:-$HOME/.steam/steam/steamapps/common/dota 2 beta}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -d "$DOTA_DIR/game/dota_addons" ]; then
	echo "ERROR: Could not find '$DOTA_DIR/game/dota_addons'."
	echo "Make sure Dota 2 Workshop Tools are installed:"
	echo "  Steam -> Dota 2 -> DLC -> check 'Dota 2 Workshop Tools'"
	echo "Then re-run:  ./install.sh \"/path/to/dota 2 beta\""
	exit 1
fi

echo "[1/2] Installing addon into $DOTA_DIR ..."
mkdir -p "$DOTA_DIR/game/dota_addons/dota-lod-deathroll"
cp -r "$SCRIPT_DIR/game/." "$DOTA_DIR/game/dota_addons/dota-lod-deathroll/"

echo "[2/2] Installing MMR server dependencies ..."
if ! command -v npm >/dev/null 2>&1; then
	echo "ERROR: Node.js/npm not found. Install Node.js LTS from https://nodejs.org and re-run."
	exit 1
fi
(cd "$SCRIPT_DIR/mmr-server" && npm install)

echo
echo "============================================================"
echo " Addon installed to:"
echo "   $DOTA_DIR/game/dota_addons/dota-lod-deathroll"
echo
echo " To play:"
echo "   1. Start the MMR server:  ./start-mmr-server.sh"
echo "   2. Open Dota 2 Workshop Tools, select 'dota-lod-deathroll'"
echo "   3. Press the Play button in Workshop Tools"
echo "============================================================"
