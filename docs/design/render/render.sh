#!/bin/bash
# Re-render all Telltale design artboards to pixel-accurate reference PNGs.
#
# Usage:
#   ./render.sh
#
# What it does:
#   1. Copies the current *.dc.html artboards from ../artboards/ into this
#      folder (support.js here is a saved copy of the Claude Design canvas's
#      dc-runtime.js — the artboards' own <script src="./support.js"> expects
#      it under that name; it also self-loads React/ReactDOM from jsdelivr).
#   2. Serves this folder over plain HTTP (python3 -m http.server).
#   3. Screenshots each artboard at its exact canvas.json size with headless
#      Chrome at --force-device-scale-factor=2, writing
#      ../reference/<Name>@2x.png.
#
# Requires: python3, Google Chrome at the path below, network access (Chrome
# fetches React/ReactDOM from cdn.jsdelivr.net on first paint).
set -euo pipefail
cd "$(dirname "$0")"

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
PORT=8791
OUT_DIR="../reference"

if [ ! -x "$CHROME" ]; then
  echo "Chrome not found at $CHROME — edit render.sh to point at your Chromium/Chrome/Edge/Brave binary." >&2
  exit 1
fi

cp ../artboards/*.dc.html .

mkdir -p "$OUT_DIR"

python3 -m http.server "$PORT" --bind 127.0.0.1 >/tmp/telltale-render-server.log 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT
sleep 1

render() {
  local name="$1" wh="$2"
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars \
    --window-size="$wh" --force-device-scale-factor=2 \
    --virtual-time-budget=6000 \
    --screenshot="$OUT_DIR/${name}@2x.png" \
    "http://127.0.0.1:${PORT}/${name}.dc.html" >/tmp/telltale-render-${name}.log 2>&1
  echo "$name -> $(file -b "$OUT_DIR/${name}@2x.png")"
}

render MenuBar      440,720
render MenuBarAlert 440,720
render StatusIcon   640,330
render Main         1280,860
render CPU          1280,860
render GPU          1280,860
render Memory       1280,860
render Network      1280,860
render Thermals     1280,860
render Power        1280,860
render Disk         1280,860
render Processes    1280,860
render History      1280,860
