# Telltale design reference renders

Pixel-accurate PNG renders of the 13 "Telltale" design artboards, for comparing
against the SwiftUI app's actual output.

## Re-render

```
bash docs/design/render/render.sh
```

(Run with `bash` explicitly — the default `zsh` on this machine doesn't do
the word-splitting the script relies on.)

This regenerates every `*@2x.png` file in this folder from the artboards in
`docs/design/artboards/`. Requires `python3`, Google Chrome at
`/Applications/Google Chrome.app`, and network access (Chrome loads
React/ReactDOM from `cdn.jsdelivr.net` on first paint of each artboard).

## How it works

The `.dc.html` artboards are Claude Design "Design Component" pages exported
from the canvas artifact (https://claude.ai/artifact/CobFLbd5RJ3Eoq3HLYpSKJ).
Each references `<script src="./support.js">`, which isn't included in a
plain export — `docs/design/render/support.js` is a saved copy of that
artifact's `artifact-type/dc-runtime.js` (185 KB), which is the actual
runtime the canvas serves as `support.js`. It parses the `<x-dc>` template and
`<script type="text/x-dc" data-dc-script>` logic block in each artboard and
renders them with React (loaded from jsdelivr if `window.React` isn't already
present).

`render.sh` copies the current artboards into `docs/design/render/`, serves
that folder with `python3 -m http.server`, and screenshots each one with
headless Chrome at its exact `canvas.json` size and
`--force-device-scale-factor=2`, so every PNG is at 2x (Retina) resolution.

## Sizes (at 2x)

| Artboard | Logical size | PNG size |
|---|---|---|
| MenuBar | 440×720 | 880×1440 |
| MenuBarAlert | 440×720 | 880×1440 |
| StatusIcon | 640×330 | 1280×660 |
| Main | 1280×860 | 2560×1720 |
| CPU | 1280×860 | 2560×1720 |
| GPU | 1280×860 | 2560×1720 |
| Memory | 1280×860 | 2560×1720 |
| Network | 1280×860 | 2560×1720 |
| Thermals | 1280×860 | 2560×1720 |
| Power | 1280×860 | 2560×1720 |
| Disk | 1280×860 | 2560×1720 |
| Processes | 1280×860 | 2560×1720 |
| History | 1280×860 | 2560×1720 |

## Source of truth

If the design changes, re-export the artboards from the canvas artifact into
`docs/design/artboards/` (keeping `canvas.json` in sync with any size
changes), then re-run `render.sh`. `support.js` only needs updating if the
canvas's runtime (`dc-runtime.js`) changes.
