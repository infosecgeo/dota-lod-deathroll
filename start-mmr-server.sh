#!/usr/bin/env bash
# Starts the LOD Deathroll local MMR server (http://localhost:3000)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/mmr-server"
if [ ! -d node_modules ]; then
	echo "Installing dependencies first..."
	npm install
fi
npm start
