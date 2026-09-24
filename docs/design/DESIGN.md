# Telltale Design Spec

Source: `docs/design/artboards/*.dc.html` (13 artboards) and the SPEC.md "Design reference" and "Rulings" sections. You do not need to open the HTML to build from this document. The design wins on look, layout and copy. The rulings win where they conflict with the design. Tags used below:

- **REMOVED**: shown in the design but not built (a ruling drops it).
- **CHANGED**: built, but different from the design (a ruling or a resolved inconsistency).
- **ADDED**: not in the design. Built in the design's visual language, to the spec given here.

Units: 1 CSS px = 1 pt. All sizes are in pt. The app is dark-only, so every color below is final and has no light variant. The one exception is the menu bar glyph (§4).

---

## 0. Global conventions

| Rule | Value |
|---|---|
| Appearance | Force dark: `NSApp.appearance = NSAppearance(named: .darkAqua)`. All windows and panels draw their own backgrounds from tokens. |
| Numerals | Every number uses tabular digits: `.monospacedDigit()` on every `Text` that shows a value, and on table cells, axis labels and badges. |
| Text rendering | Antialiased and not bold-adjusted. The design used `-webkit-font-smoothing: antialiased`, which is the macOS default. |
| Tracking | 0 everywhere. The design sets no letter-spacing. Rely on SF's built-in optical tracking. |
| Line height | Default font line height, except descriptive paragraphs (see `Font.tt.body12Para`). |
| Separators in copy | ` · ` (space, U+00B7, space). The minus sign is U+2212 `−`. "Unavailable" is U+2014 `—`. Arrows are `↓` U+2193 and `↑` U+2191, followed by a space. |
| Truncation | Single line, `.lineLimit(1)`. Tail truncation unless §5.9 says otherwise. |
| Hit targets | The minimum clickable size is the visual size given here. Do not pad invisibly beyond 4 pt. |

---

## 1. Tokens

### 1.1 Colors

Swift: `extension Color { enum tt { static let bgWindow = Color(hex: 0x1B1B1D) … } }`. Alpha colors are `Color.white.opacity(x)` or `Color(hex:…).opacity(x)`. Write them exactly as listed, and do not pre-blend them against a background.

#### Backgrounds (by elevation, low to high)

| Token | Value | Use |
|---|---|---|
| `bgWindow` | `#1B1B1D` | Dashboard main content area, Settings content |
| `bgHeader` | `#202023` | Page header / toolbar strip (52 pt) |
| `bgCard` | `#232326` | Every card/section, stat strip, inspector |
| `bgSidebar` | `#242427` | Sidebar |
| `bgPopover` | `#28282C` @ 0.97 | Menu bar popover panel |
| `bgElevated` | `#2C2C30` | Modal dialog, History event chips |
| `bgScrim` | `#000000` @ 0.45 | Behind modal dialog |

Artboard-only values. Do not build these: `#121317` is the fake desktop behind the popover. `rgba(28,28,32,0.92)` is the fake menu bar. `#1D1E22` is the status-icon demo card.

#### Text

| Token | Value | Use |
|---|---|---|
| `textPrimary` | `#F2F2F4` | Titles, values, table cells |
| `textSecondary` | `#A8A8B0` | Subtitles, labels, legends, units, table headers, icon-button glyphs |
| `textTertiary` | `#9A9AA2` | Sidebar section headers, axis labels, stat sub-lines, chevrons, "—", hints |
| `textOnAccent` | `#FFFFFF` | Text on accent, destructive, and letter tiles |
| `link` | `#6CB4FF` | Text links ("Open History", "All processes", "Details") |
| `linkHover` | `#9CCBFF` | Link hover |

#### Borders, dividers, fills

| Token | Value | Use |
|---|---|---|
| `borderCard` | white @ 0.07 | 1 pt card border |
| `borderWindow` | white @ 0.12 | Window outline (the native window draws this; listed for reference) |
| `borderPopover` | white @ 0.14 | Popover and dialog 1 pt border, event chip border |
| `borderControl` | white @ 0.08 | 1 pt border of secondary buttons |
| `borderSwatch` | white @ 0.15 | Memory composition legend swatch border |
| `separator` | white @ 0.08 | Table header bottom rule, key-value row rules, popover dividers, sidebar footer rule, thin progress tracks |
| `edgeSidebar` | black @ 0.50 | Sidebar right edge, 1 pt |
| `edgeHeader` | black @ 0.45 | Header bottom edge, 1 pt |
| `fillTrack` | white @ 0.06 | Per-core bar track, pill badge bg |
| `fillField` | white @ 0.07 | Segmented-control container, search field |
| `fillZebra` | white @ 0.025 | Odd table rows (index 1, 3, 5 …) |
| `fillHover` | white @ 0.05 | ADDED: row/sidebar hover |
| `fillSelectedSidebar` | white @ 0.10 | Selected sidebar item |
| `fillSegmentOn` | white @ 0.18 | Selected segment |
| `fillButton` | white @ 0.10 | Secondary button bg |
| `fillButtonHover` | white @ 0.14 | ADDED: secondary button hover |
| `fillIconButton` | white @ 0.08 | Filled icon button (eject), icon-button hover |
| `fillRest` | white @ 0.14 | "Remaining" segment of the power split bar |
| `fillFree` | white @ 0.08 | Free-memory segment, empty bar tracks |
| `rowSelected` | `#0A84FF` @ 0.28 | Selected table row (CHANGED: unified, see §6) |

#### Accent and actions

| Token | Value | Use |
|---|---|---|
| `accent` | `#0A84FF` | Primary buttons, selected fan-mode button (removed), toggles, slider, text-field caret |
| `destructive` | `#C9302C` | Force Quit button fill and border |

#### Category accents

| Token | Hex | Category / series |
|---|---|---|
| `cpu` | `#5EA8FF` | CPU, P-cores, CPU "User" series, CPU power |
| `cpuAlt` | `#9CC9FF` | E-cores, CPU "System" series |
| `cpuLine` | `#CFE4FF` | CPU total outline (stroke opacity 0.9) |
| `gpu` | `#BF8CFF` | GPU, GPU power, media-engine bars |
| `gpuAlt` | `#E6D7FF` | GPU frequency (dashed) |
| `mem` | `#4FD1A5` | Memory, App memory |
| `memWired` | `#2F9E7A` | Wired |
| `memCompressed` | `#A7F0D4` | Compressed, swap series |
| `memCached` | `#4FD1A5` @ 0.28 | Cached files |
| `net` | `#FFA24C` | Network, download |
| `netUp` | `#FFD0A3` | Upload |
| `thermal` | `#FF7A6B` | Thermals, P-core temp series, fan gauge, sensor bars |
| `thermalGPU` | `#FFC2B8` | GPU temp series |
| `thermalBattery` | `#A8564D` | Battery temp series |
| `power` | `#FFD24C` | Power, package, ANE |
| `dram` | `#8E8E96` | DRAM power |
| `disk` | `#F07AB8` | Disk, read, used |
| `diskWrite` | `#FFC4E1` | Write |
| `diskPurgeable` | `#F07AB8` @ 0.35 | Purgeable |
| `battery` | `#32D74B` | Battery glyph and fill (same hex as `statusCalm`) |

#### Status

| Token | Value | Use |
|---|---|---|
| `statusCalm` | `#32D74B` | "All systems nominal" dot, Nominal, Active, Healthy |
| `statusFair` | `#C8D64A` | Thermal pressure "Fair" segment and value |
| `statusElevated` | `#FFB340` | Elevated icon arc/dot, alert banner, Serious, memory Warning, "Preventing sleep: Yes" |
| `statusCritical` | `#FF453A` | Critical icon arc/dot, Critical, memory Critical |
| `statusElevatedRowFill` | `#FFB340` @ 0.12 | Stressed popover row bg |
| `statusElevatedBannerFill` | `#FFB340` @ 0.14 | Banner bg, History thermal band (as `opacity 0.14` of solid `#FFB340`) |
| `statusElevatedBannerBorder` | `#FFB340` @ 0.35 | Banner border |
| `statusElevatedSwatch` | `#FFB340` @ 0.50 | History legend swatch |
| `statusCritical*` | `#FF453A` at the same 0.12 / 0.14 / 0.35 / 0.50 | ADDED: critical variants of the four above |
| `statusPaused` | `#9A9AA2` | ADDED: status dot while sampling is paused |

#### App letter tiles (fallback when an app has no icon; see §2.19)

`tile0 #2F5FB3`, `tile1 #5B3FA8`, `tile2 #2A6F80`, `tile3 #8A4B2A`, `tile4 #3D6B35`, `tile5 #8C2F5A`, `tile6 #4D5260`, `tile7 #6B5A1F`. Pick the index as a stable hash (FNV-1a) of the bundle ID or executable name, mod 8.

#### Chart series fills (opacity applied to the series hex)

| Chart | Area fill opacity | Line |
|---|---|---|
| Popover sparkline, Overview tile sparkline, History lanes | 0.22 | 1.25 pt (popover, History) / 1.5 pt (Overview tile) |
| Overview "Last 60 seconds" rows | 0.18 | 1.25 pt |
| GPU utilization, Memory pressure | 0.25 | 1.5 pt |
| ANE, Swap | 0.20 | 1.5 pt |
| Network ↓ / ↑ | 0.30 / 0.25 | 1.5 pt |
| Disk read / write | 0.30 / 0.25 | 1.5 pt |
| CPU Usage stacked | System (total) `cpuAlt` 0.35, User `cpu` 0.55 | Total outline `cpuLine` 1.25 pt @ 0.9 |
| Power stacked | CPU 0.75, GPU 0.70, ANE 0.80, DRAM 0.55 | none |
| Thermals lines | none | P-cores 1.75 pt, GPU 1.5 pt, Battery 1.5 pt |
| GPU frequency | none | `gpuAlt` 1.25 pt @ 0.7, dash `[3, 3]` |

All lines use round joins. Line caps are butt (the SVG default).

### 1.2 Typography

The design used `-apple-system, "SF Pro Text"`, which maps to `Font.system` (SF Pro, with automatic Text/Display optical sizes). For mono it used `ui-monospace, "SF Mono"`, which maps to `Font.system(size:, design: .monospaced)`. No other families appear. Every numeric token adds `.monospacedDigit()`.

Swift: `extension Font { enum tt { static let stat = Font.system(size: 20, weight: .semibold).monospacedDigit() … } }`

| Token | Size / weight | Line height (approx.) | Use |
|---|---|---|---|
| `display` | 26 / semibold | 31 | Overview tile value |
| `displayUnit` | 15 / regular, `textSecondary` | — | Unit after `display` ("%", " GB", "°C", "↓ ") |
| `title1` | 24 / semibold | 29 | Power card value, battery % |
| `title1Unit` | 14 / regular, `textSecondary` | — | " W package" |
| `title2` | 22 / semibold | 26 | ANE value, Swap headline, History "At" time |
| `title2Unit` | 13 / regular, `textSecondary` | — | " of 2.00 GB" |
| `stat` | 20 / semibold | 24 | Stat strip values |
| `statMedium` | 18 / semibold | 22 | Fan rpm |
| `pageTitle` | 15 / semibold | 18 | Page header h1, inspector name, 15-pt value blocks (composition legend, History lane values, inspector stats) |
| `dialogTitle` | 14 / semibold | 17 | Dialog title, History "Top process" |
| `sectionTitle` | 13 / semibold | 16 | Card h2 titles, popover app name "Telltale", volume name, interface name |
| `body13` | 13 / regular | 16 | Sidebar items, popover row titles, top-consumer name |
| `body13Value` | 13 / semibold | 16 | Popover row value (74-pt column) |
| `button13` | 13 / medium | 16 | Regular buttons (28 pt), popover footer buttons (30 pt) |
| `body12` | 12 / regular | 14 | Table cells, links, key-value rows, legend-free meta, compact popover rows |
| `body12Strong` | 12 / semibold | 14 | Per-core value, tile header ("CPU"), sidebar device name, active thermal level |
| `button12` | 12 / medium | 14 | Small buttons (24 pt), segmented segments |
| `body12Para` | 12 / regular, line spacing 4 (≈1.5×) | 18 | Descriptive paragraphs, dialog body, History note |
| `bannerText` | 12 / regular, line spacing 3 (≈1.45×) | 17 | Popover alert banner |
| `caption` | 11 / regular | 13 | Subtitles, stat labels, legends, badges, sub-lines |
| `captionMedium` | 11 / medium | 13 | Table header cells, pill badges |
| `captionStrong` | 11 / semibold | 13 | Sidebar section headers ("Monitor", "System", "Activity") |
| `mono11` | 11 / regular, monospaced | 13 | IP addresses, executable paths |
| `micro` | 10 / regular | 12 | Chart axis labels |
| `tileLetter20` | 10 / bold | — | Letter in a 20-pt tile |
| `tileLetter26` | 13 / bold | — | Letter in a 26-pt tile |
| `tileLetter44` | 20 / bold | — | Letter in a 44-pt tile |

### 1.3 Spacing, radii, strokes, shadows, opacity

Swift: `enum TT { enum Space { static let x2: CGFloat = 2 … } enum Radius { … } enum Stroke { … } }`

**Spacing scale** (every gap and padding in the design falls on it): `x1 1`, `x2 2`, `x3 3`, `x4 4`, `x5 5`, `x6 6`, `x7 7`, `x8 8`, `x9 9`, `x10 10`, `x12 12`, `x14 14`, `x16 16`, `x18 18`, `x20 20`, `x21 21`, `x24 24`, `x32 32`. (`x5` is the media-engine row gap; `x21` is the History lane value indent.)

Semantic aliases:

| Alias | Value |
|---|---|
| `pagePadding` | 20 (content inset on all four sides) |
| `gridGap` | 12 (between cards, rows and columns) |
| `cardPadding` | 16 (variants: 14 for the Overview tile horizontal/vertical `14×16`, and Media engines `14`) |
| `statCellPadding` | 12 vertical × 16 horizontal |
| `tableCellGap` | 12 (column gap) |
| `tableRowInset` | 12 (horizontal) |
| `legendGap` | 14 |
| `iconTextGap` | 7 (card header), 8 (table name cell), 9 (sidebar), 10 (popover row) |

**Radii**

| Token | pt | Use |
|---|---|---|
| `r2` | 2 | Legend swatch 8×8 |
| `r2_5` | 2.5 | 5-pt progress bar |
| `r3` | 3 | 6-pt thermal-pressure segment |
| `r4` | 4 | Per-core fill, 8-pt bars, menu bar button, treemap tile (ADDED) |
| `r5` | 5 | Segment button, 20-pt letter tile, row action button, composition bar, 10-pt volume bar (5 = h/2) |
| `r6` | 6 | Buttons, sidebar item, table row, per-core track, icon buttons |
| `r7` | 7 | Segmented container, search field, popover row, popover footer buttons, 26-pt tile |
| `r8` | 8 | Alert banner |
| `r9` | 9 | Battery outline |
| `card` | 10 | Cards, 44-pt tile |
| `pill` | 11 | Badges and chips (height 22) |
| `window` | 12 | Popover, dialog, window |

Dots: 7×7 status dot radius 3.5 (the design says 4, which is the same thing: a circle).

**Strokes**: `hairline 1` (all borders and dividers), `icon 1.5` (all 16-grid icons), `iconFan 1.4` (fan glyph inside the gauge only), `sparkThin 1.25`, `spark 1.5`, `sparkHeavy 1.75`, `cursor 1.5` (History scrub line), `gauge 7` (fan gauge), `glyph 2.2` (status icon, viewBox units), `batteryOutline 2`.

**Shadows**

| Token | Value |
|---|---|
| `shadowPopover` | y 18, blur 50, black @ 0.60 (SwiftUI `radius` = 25) |
| `shadowDialog` | y 24, blur 60, black @ 0.55 (`radius` = 30) |

**Opacity levels**: `0.025` zebra, `0.05` hover (ADDED), `0.06` track, `0.07` card border and field, `0.08` separator, `0.10` button, `0.12` stressed row, `0.14` banner and band, `0.18` segment on, `0.22` sparkline fill, `0.28` inactive thermal segment and row selection, `0.35` banner border and purgeable, `0.40` disabled (ADDED), `0.45` scrim, `0.50` swatch, `0.85` cursor.

### 1.4 Icons

All icons sit on a 16×16 grid with stroke 1.5, round caps, round joins and no fill, unless noted. They render at 16 pt (sidebar, popover, tile headers), 14 pt (timeline labels, search, eject) or 18 pt (volume). Build them as `Shape`s from these paths. Do not substitute SF Symbols, because the metrics differ.

| Name | Path(s) (SVG, 16 grid) | Color |
|---|---|---|
| `overview` | 4 rects `rx 1`, each 4.5×4.5 at (2.5,2.5), (9,2.5), (2.5,9), (9,9) | `textSecondary` |
| `cpu` | rect (4,4,8,8) rx 1.5; rect (6.5,6.5,3,3); `M6 1.5v2M10 1.5v2M6 12.5v2M10 12.5v2M1.5 6h2M1.5 10h2M12.5 6h2M12.5 10h2` | `cpu` |
| `gpu` | rect (1.5,4,13,8) rx 1.5; circle (6,8) r2; `M10 6.5h2.5M10 9.5h2.5` | `gpu` |
| `memory` | rect (1.5,4.5,13,6) rx 1; `M4.5 10.5v2M7 10.5v2M9.5 10.5v2M12 10.5v2M4.5 7.5h1M7 7.5h1M9.5 7.5h1` | `mem` |
| `network` | `M5 13V3M5 3L2.5 5.5M5 3l2.5 2.5M11 3v10M11 13l-2.5-2.5M11 13l2.5-2.5` | `net` |
| `thermals` | `M9.5 9.2V3a1.5 1.5 0 0 0-3 0v6.2a3 3 0 1 0 3 0z` + `M8 7v4` | `thermal` |
| `power` | `M9 1.5L3.5 9H8l-1 5.5L12.5 7H8z` | `power` |
| `disk` | ellipse (8,4) rx 5.5 ry 2; `M2.5 4v8c0 1.1 2.5 2 5.5 2s5.5-.9 5.5-2V4M2.5 8c0 1.1 2.5 2 5.5 2s5.5-.9 5.5-2` | `disk` |
| `processes` | `M5.5 4h8M5.5 8h8M5.5 12h8`; circles r 0.75 at (2.75, 4/8/12) | `textSecondary` |
| `history` | circle (8,8) r6; `M8 4.5V8l2.5 1.5` | `textSecondary` |
| `pause` | `M6 3.5v9M10 3.5v9` | `textSecondary` |
| `play` (ADDED) | `M5 3.5v9l7-4.5z` | `textSecondary` |
| `settings` | `M2 4.5h7M12 4.5h2M2 11.5h2M7 11.5h7`; circles r 1.5 at (10.5,4.5), (5.5,11.5) | `textSecondary` |
| `chevronRight` | `M6 3.5L10.5 8 6 12.5` (drawn at 12 pt) | `textTertiary` |
| `chevronDown` (ADDED) | `M3.5 6L8 10.5 12.5 6` | `textTertiary` |
| `ellipsis` | circles r 0.9 at (3.5,8), (8,8), (12.5,8) | `textSecondary` |
| `search` | circle (7,7) r4.5; `M10.5 10.5L14 14` | `textSecondary` |
| `battery` | rect (1.5,4.5,11.5,7) rx 1.5; `M14.5 7v2` | `battery` |
| `fan` | circle (8,8) r1.5; `M8 6.5C8 3 10.5 2 12 3.5M9.5 8c3.5 0 4.5 2.5 3 4M8 9.5c0 3.5-2.5 4.5-4 3M6.5 8C3 8 2 5.5 3.5 4` | `thermal`, stroke 1.5 (Fans card header, 16 pt) / `textSecondary`, stroke 1.4 (inside the gauge, 18 pt) |
| `eject` | `M8 3L3 9h10z`; `M3 12.5h10` | `textSecondary` |
| `quit` (ADDED) | `M8 2v5.5`; `M4.4 4.2a5 5 0 1 0 7.2 0` | `textSecondary` |
| `dragHandle` (ADDED) | `M4 5.5h8M4 8h8M4 10.5h8` | `textTertiary` |

---

## 2. Components

The "Artboards" column refers to: MB = MenuBar, MBA = MenuBarAlert, SI = StatusIcon, OV = Overview (Main), and CPU, GPU, MEM, NET, THR, PWR, DSK, PRC, HIS.

### 2.1 Card (`TTCard`)
- bg `bgCard`, 1-pt `borderCard`, radius `card` 10, padding 16. The content is a VStack with a per-card gap: 12 by default, 10 for chart cards, 8 for table cards, 6 for ANE and sensors.
- **Card header** (`TTCardHeader`): HStack, gap 8, min-height 20. Optional leading 16-pt icon, then the title `sectionTitle` (flex-grow), then an optional trailing element: a link (`body12`, `link`), a caption (`body12`, `textSecondary`), a legend, or a badge.
- Hover: none. Cards that navigate use the metric tile instead (§2.4).
- Artboards: every dashboard artboard.

### 2.2 Stat strip (`TTStatStrip`)
- One card with no padding. Its content is N equal columns (`repeat(N, 1fr)`) with no dividers. N is 4, 5 or 6 per page.
- Each cell: VStack, gap 3, padding 12×16:
  - label: `caption`, `textSecondary`
  - value: `stat` (20/600). The value is `textPrimary`, except the first cell, which uses the category accent.
  - sub (optional): `caption`, `textTertiary`
- Height: intrinsic, about 80 plus 2 of border. All cells align to the top. A cell without a sub-line leaves the space empty.
- Values must not wrap (`lineLimit(1)`, `minimumScaleFactor(0.8)`).
- Artboards: CPU(6), GPU(5), MEM(5), NET(5), THR(4), PWR(6), DSK(4).

### 2.3 Sparkline / area chart (`TTAreaChart`)
- An area plus a line over the same series. The series color and opacities come from §1.1. The line is drawn after the area.
- x runs 0…w evenly across N samples (`x = i/(N−1)·w`). y is clamped to [0, max]. The y-domain is fixed per metric (§5.10).
- There are no axes, gridlines or points. `overflow: visible`: the line may bleed 1 pt past the frame.
- **Gap rule** (ADDED): a missing sample (paused, asleep, not yet collected) breaks both the line and the area. Never interpolate across a gap.
- Sizes:

| Where | Size | Line | Fill |
|---|---|---|---|
| Popover row | 84×22 | 1.25 | 0.22 |
| Overview tile | fill width (≈160)×40 | 1.5 | 0.22 |
| Overview timeline row | 480×30 | 1.25 | 0.18 |
| GPU utilization | fill (≈640)×160 | 1.5 | 0.25 |
| ANE | fill (≈290)×44 | 1.5 | 0.20 |
| Memory pressure | fill×150 | 1.5 | 0.25 |
| Swap | fill×50 | 1.5 | 0.20 |
| History lane | fill (≈810)×48 | 1.25 | 0.22 |
| App detail row (ADDED) | fill×30 | 1.25 | 0.18 |

### 2.4 Overview metric tile (`TTMetricTile`)
- A card with padding 14 (vertical) × 16 (horizontal), height 168, VStack gap 6. The whole tile is a button that navigates to the category page.
  1. Header HStack, gap 7: category icon 16, title `body12Strong` (flex), `chevronRight` 12 in `textTertiary`.
  2. Value: `display` plus a unit in `displayUnit`, with 2 of top margin. Network puts its unit before the value: `↓ ` in `displayUnit`, then the value `12.4 MB/s` in `display`.
  3. Sub: `caption`, `textSecondary`, tail truncation.
  4. Spacer.
  5. Sparkline, full width × 40.
- Hover (ADDED): border white @ 0.14. Pressed: bg white @ 0.03 overlay.
- Artboard: OV.

### 2.5 Timeline row (`TTTimelineRow`)
- HStack, gap 12, height 34:
  - label box, 84 wide: HStack gap 7, icon 14 plus `body12` in `textSecondary`
  - sparkline 480×30 (fills the width in App detail)
  - value: flex, right-aligned, `body12` in `textPrimary`
- Rows stack with gap 4. Below the last row sits an axis row (§2.12) with left inset 96 (84 + 12).
- Artboards: OV; App detail (ADDED).

### 2.6 Cluster bars (per-core) (`TTCoreBars`)
- Grid with `repeat(n, 1fr)` columns and gap 10 (8 columns for P-cores, 4 for E-cores).
- Each column is a VStack, center-aligned, gap 6:
  - value `body12Strong` with "%" (for example `72%`)
  - track: width 100% capped at 44, height 104, radius 6, `fillTrack`. It clips a bottom-aligned fill whose height is `pct%`, radius 4, colored `cpu` (P) or `cpuAlt` (E).
  - label `caption` in `textSecondary`: `P1…P8`, `E1…E4`
- Footer: HStack gap 18, `caption`, `textSecondary`.
- Animation: height changes animate with `.easeOut(duration: 0.25)`.
- Artboard: CPU.

### 2.7 Stacked area chart (`TTStackedArea`)
- Draw cumulative areas from the largest sum down to the smallest: `pw4 = CPU+GPU+ANE+DRAM` (dram color), `pw3 = CPU+GPU+ANE` (power), `pw2 = CPU+GPU` (gpu), `pw1 = CPU` (cpu). Each layer is filled over the full height from the baseline, so the layers overlap and are not banded.
- The CPU Usage chart works the same way: `usr+sys` in `cpuAlt` @ 0.35, then `usr` in `cpu` @ 0.55, then an outline of `usr+sys` in `cpuLine` 1.25 @ 0.9.
- A legend sits in the card header. There are no axes.
- Artboards: CPU (988×110, meaning full width), PWR (fill×160, y-max 30 W, or auto; see §5.10).

### 2.8 Mirrored chart (`TTMirroredChart`)
- A VStack with no gap:
  - top half: an area that grows upward from the bottom edge (h 90 for Network, 80 for Disk)
  - a 1-pt divider, white @ 0.18
  - bottom half: an area that hangs downward from the top edge (same height)
- Each half has its own y-scale. The legend states the scale: "Download · scale 40 MB/s", "Upload · scale 4 MB/s". Disk has a single shared scale and shows it as a third legend item with a transparent swatch: "scale 600 MB/s".
- Artboards: NET, DSK.

### 2.9 Multi-line chart with y-axis (`TTLineChart`)
- HStack gap 10: a y-label column (height 150, space-between, 5 labels in `micro` `textTertiary`, e.g. `105° 89° 72° 56° 40°`), then the chart (fill × 150).
- Lines only; widths per §1.1. The axis row below is inset 34 from the left.
- Artboard: THR.

### 2.10 Line + dashed overlay (`TTDualChart`)
- The utilization area/line (0–100%) with the frequency line on its own scale (0…max MHz) overlaid: dashed `[3,3]`, `gpuAlt` 1.25 @ 0.7.
- Artboard: GPU.

### 2.11 Legend (`TTLegend`)
- HStack gap 14. Each item is an HStack of gap 6: a swatch 8×8 with radius 2 in the series color, then `caption` in `textSecondary`.
- In the Memory composition legend, swatches also get a 1-pt `borderSwatch`.

### 2.12 Time axis (`TTTimeAxis`)
- HStack with space-between across the chart width. Labels are `micro` in `textTertiary`.
- Label sets:
  - Live: `60 s ago · 45 s · 30 s · 15 s · now`
  - 1H: `60 m ago · 45 m · 30 m · 15 m · now`
  - 24H (History): `00:00 · 04:00 · … · 24:00` (7 labels). On category pages, 24H uses `24 h ago · 18 h · 12 h · 6 h · now`.
  - 7D: 7 short weekday labels, ending with today
  - 30D: 5 dates `d MMM`, ending with today
- The last four sets are ADDED; the design shows only Live and 24H.

### 2.13 Range segmented control (`TTSegmented`)
- Container: HStack gap 2, padding 2, radius 7, `fillField`. Total height 28.
- Segment: height 24, horizontal padding 10, radius 5, `button12`.
  - on: `fillSegmentOn` bg, `textPrimary`
  - off: transparent bg, `textSecondary`
  - hover (ADDED): off segments get `fillHover`
- The segment switches instantly, with no slide animation.
- The same component is used for Sort by, Apps/Processes (ADDED), and Settings units (ADDED).
- **Compact variant** (ADDED; used for the App detail range and the treemap metric): container padding 2, gap 2, radius 6, total height 24. Segment height 20, horizontal padding 8, radius 4, font `captionMedium` (11/500). Colors and states are the same as the regular variant.
- Ranges (CHANGED per ruling): every page, History included, shows `Live 1H 24H 7D 30D`. The design omitted Live on History and 30D elsewhere. The default is Live on Overview and the category pages, and 24H on History.

### 2.14 Buttons

| Variant | Height | Padding h | Radius | Font | Fill / border / text |
|---|---|---|---|---|---|
| `small` secondary | 24 | 10 | 6 | `button12` | `fillButton` / 1 `borderControl` / `textPrimary` |
| `small` destructive | 24 | 10 | 6 | `button12` | `destructive` / 1 `destructive` / white |
| `small` primary | 24 | 10 | 6 | `button12` | `accent` / 1 `accent` / white |
| `regular` secondary | 28 | 12 | 6 | `button13` | as small secondary |
| `regular` destructive | 28 | 12 | 6 | `button13` | as small destructive |
| `popoverPrimary` | 30 | fill width | 7 | `button13` | `accent` / none / white |
| `popoverSecondary` | 30 | 12 | 7 | `button13` | `fillButton` / none / `textPrimary` |
| `iconButton` | 26 (popover) / 28 (header) | — | 6 | glyph 16 | transparent / none / `textSecondary` |
| `iconButtonFilled` | 26 | — | 6 | glyph 14 | `fillIconButton` |
| `rowAction` | 24 | — | 5 | `ellipsis` 16 | transparent / `textSecondary` |
| `link` | text | — | — | `body12` | `link`, hover `linkHover`, no underline |
| `chip` | 22 | 8 | 11 | `caption` | `bgElevated` / 1 `borderPopover` / `textPrimary` |

States (ADDED, the design shows only rest):
- hover: secondary becomes `fillButtonHover`; primary and destructive become brightness +0.06; icon buttons get the `fillIconButton` bg.
- pressed: opacity 0.8.
- disabled: opacity 0.40, with no hover.
- focus: the system focus ring.
- Every icon-only button has a `.help()` tooltip and an accessibility label that match the design's aria-labels: "Pause sampling", "Settings", "Actions for {name}", "Eject {volume}".

### 2.15 Pill badge (`TTBadge`)
- Height 22, horizontal padding 8, radius 11, `fillTrack`. HStack gap 6: a 7×7 dot in the status or category color, then `captionMedium` in `textPrimary`.
- Examples: "8 cores", "16 cores", "Active", "Healthy".
- Artboards: CPU, GPU, NET, DSK.

### 2.16 Progress bars
- `thin`: height 5, radius 2.5, track `separator`, fill in the category color. Used for media engines and sensor rows.
- `medium`: height 8, radius 4, track `fillFree`. Used for the Overview disk card.
- `volume`: height 10, radius 5, track `fillFree`, with segments `used` then `purgeable` and a gap of 2.
- `split` (power): height 8, radius 4, gap 2, clipped. The segments are CPU/GPU/ANE/DRAM as fractions of package power, plus a remainder in `fillRest`.
- `composition` (memory): height 18, radius 5, gap 2, clipped. Segments in order are App (`mem`), Wired (`memWired`), Compressed (`memCompressed`), Cached (`memCached`), Free (`fillFree`), each as a fraction of total RAM.
- `thermalScale`: 4 equal columns with gap 6. Each column has a bar 6 tall with radius 3, in the level color at opacity 1 when current and 0.28 otherwise. Below it, a label in `body12`, semibold `textPrimary` when current and regular `textSecondary` otherwise. Below that, a description in `caption` `textTertiary`. Only the current level is lit.

### 2.17 Fan gauge (`TTFanGauge`)
- A 76×76 frame with center (38,38), r 30 and stroke 7 with round caps.
- The track spans 270°: it starts at the 7:30 position (135° measured clockwise from 3 o'clock) and runs clockwise to 4:30. Color white @ 0.08.
- The value arc has the same start and a length of `270° × rpm / maxRPM`, in `thermal`.
- Center: the `fan` glyph at 18 pt (16 × 1.125), stroke 1.4, `textSecondary`.
- To its right, a VStack gap 2: label `body12` in `textSecondary` ("Left fan"), value `statMedium` ("2,140 rpm"), sub `caption` in `textTertiary` ("max 5,700"). Gauge and text are separated by 14.
- The value animates `.easeOut(0.4)`.

### 2.18 Key-value list (`TTKeyValueList`)
- Rows are HStacks with space-between, gap 12, vertical padding 7, `body12`. The label is `textSecondary`; the value is `textPrimary`, right-aligned and tabular.
- Each row has a bottom 1-pt `separator` except the last.
- A value may be a mono span (`mono11`, used for IPs) or a small button.
- Artboards: MEM (Swap), NET, PWR, DSK.

### 2.19 App tile (`TTAppTile`)
- Sizes are 20 (tables, radius 5, letter `tileLetter20`), 26 (popover, radius 7, `tileLetter26`) and 44 (inspector, radius 10, `tileLetter44`).
- CHANGED: when the process has a bundle icon (`NSWorkspace.shared.icon(forFile:)` on the responsible app's bundle), draw the icon at the tile size with no background.
- Otherwise draw a letter tile: the palette color from §1.1, and the uppercase first alphanumeric character in white, centered.
- ADDED child-process rows use a 16-pt tile with radius 4 and letter 9/bold.

### 2.20 Data table (`TTTable`)
- Built as a Grid or LazyVStack with fixed column templates; each page gives its template.
- Header row: height 26 (28 on Processes), horizontal padding 12, column gap 12, `captionMedium` in `textSecondary`, bottom 1-pt `separator`. Alignment is per column: text columns left, numeric right.
- The body has 4 of top padding. Processes adds a row gap of 1.
- Row: height 34 (32 for Disk, 28 for Sensors, 30 for ADDED child rows and connections), horizontal padding 12, radius 6, `body12` in `textPrimary`, tabular.
  - Zebra: odd rows `fillZebra`.
  - Name cell: HStack gap 8 of tile 20 and name (tail). Optionally an inline kind label in `caption` `textTertiary` ("App", "System", "Background").
  - User cell: `textSecondary`.
  - Actions cell: 28 wide, containing a `rowAction` button. Tables with inline actions use a 170-wide actions column (CPU, PWR).
- States:
  - hover (ADDED): `fillHover` overlays the zebra.
  - selected: `rowSelected`.
  - In the CPU and Power tables, a selected user-owned row replaces `…` with an HStack gap 6 of [Quit (small secondary)] [Force Quit (small destructive)]. Force Quit always confirms (§3.12).
  - Alignment in the 170-wide actions column: the inline [Quit][Force Quit] pair is **leading-aligned**; the `…` button on unselected rows is **trailing-aligned**.
- Context menu (ADDED): right-click any row, or click `…`, to open the row actions menu (§2.25).
- Sorting: on Processes, via the Sort-by control. Other tables are fixed-sorted by their headline metric, descending.
- Empty state (ADDED): §3.15.

### 2.21 Sidebar item (`TTSidebarItem`)
- Height 30, horizontal padding 10, radius 6, HStack gap 9: icon 16 in its category color (Overview, Processes and History use `textSecondary`), title `body13` (flex), optional trailing value in `caption` `textSecondary`, tabular.
- Items are separated by a gap of 1.
- States: selected `fillSelectedSidebar`; hover (ADDED) `fillHover`. The text color never changes.

### 2.22 Popover category row (`TTPopoverRow`)
- **Full** row: height 44, horizontal padding 10, radius 7, HStack gap 10:
  - icon 16 in the category color
  - VStack (flex, min-width 0): title `body13`, sub `caption` in `textSecondary`, no wrap
  - sparkline 84×22
  - value: 74 wide, right-aligned, `body13Value`
- **Compact** row (Power, Disk): height 36, same padding and gap, `body12` tabular:
  - icon 16
  - title (flex)
  - detail in `textSecondary`
  - value: 74 wide, right-aligned, semibold
- States:
  - rest: transparent
  - hover (ADDED): `fillHover`
  - stressed: `statusElevatedRowFill` (or the critical variant), with the value colored in the status color
- **Click** (ADDED): opens the dashboard on that category's page.
- **Top-apps flyout** (ADDED, replaces the former click-to-expand top 3): hovering a row 250 ms opens a panel beside the popover (left; right when the left has no room), its top aligned with the row and clamped 8 inside the visible frame; moving to another row switches it at once; the pointer may cross into the flyout (hover bridge); leaving both closes it after 200 ms; closing the popover closes it. Keyboard/VoiceOver: row action "Show top apps". Chrome as the popover (`bgPopover`, 1-pt `borderPopover`, radius 12, padding 6), 320 wide. Header (padding 8/10/6, gap 8): icon 16, "Top CPU" `body12Strong` + " · 34% total" `textSecondary` (the system value: row headline; Network ↓+↑, Disk read+write; Thermals shows the temperature without "total"); Thermals adds "by power" (`caption` `textTertiary`). Up to 10 lines of 26, radius 6, hover `fillHover`, padding 10, gap 8: tile 16, name `body12` middle-truncated (flex), share bar 48×4 (`fillTrack` track, category-color fill = app value / Σ of all apps' values), value 64 wide right-aligned `body12` tabular `textSecondary`. Metric per row: CPU % CPU; GPU % GPU; Memory resident memory; Network ↓+↑ rate; Thermals and Power energy W; Disk read+write rate. Clicking a line opens the dashboard on Processes with that app selected and its detail expanded. No apps: "No app activity" `caption` `textTertiary`. Updates live every tick.

### 2.23 Alert banner (`TTAlertBanner`)
- Margin 2 top, 6 horizontal, 6 bottom. Padding 10×12, radius 8, bg `statusElevatedBannerFill` with 1-pt `statusElevatedBannerBorder`. Critical uses the red variants.
- VStack gap 8: text `bannerText` in `textPrimary`, then an HStack gap 6 of small secondary buttons.
- Artboard: MBA.

### 2.24 Status glyph (`TTStatusGlyph`)
- See §4. It appears in the menu bar (18-pt canvas, glyph scaled 8/9) and in the popover header. The header glyph is the 18-unit viewBox drawn into a 20×20 frame (scale 20/18, **no** 8/9 factor: r 7.11, stroke 2.44), with the same state coloring as the menu bar.

### 2.25 Row actions menu (ADDED)
- A native `NSMenu` (dark), opened by right-clicking a row, clicking `…`, or clicking `…` in the inspector. Items:
  1. `Quit`: `NSRunningApplication.terminate()` for apps, SIGTERM for processes.
  2. `Force Quit…`: opens the confirm dialog, then `forceTerminate()` or SIGKILL.
  - Ruling (final review A-I3): Quit on an app group asks only the app to quit (`terminate()` on its regular-app members; SIGTERM to the group leader only for bundle-less groups), never its helpers; Force Quit kills every member. Every pid is start-time verified right before the signal; a gone or reused pid is skipped ("Process has exited"). A quit the app hasn't finished within 2 s toasts "Asked {name} to quit.".
  3. separator
  4. `Reveal in Finder`: `NSWorkspace.activateFileViewerSelecting([bundleOrExecURL])`. Disabled when there is no path.
  5. `Open in Activity Monitor`: launches `com.apple.ActivityMonitor`.
- For processes owned by root or another user (`uid != getuid()`), Quit and Force Quit are disabled. The menu starts with a section header "Owned by {user}" (`NSMenuItem.sectionHeader`). Reveal and Open stay enabled.
- For the Telltale process itself, Quit is enabled and quits Telltale. Force Quit is hidden.

### 2.26 Modal confirm dialog (`TTConfirmDialog`)
- Scrim `bgScrim` covers the whole window content, including the sidebar.
- The dialog is 380 wide, horizontally centered, with its top at y = 52 (just under the header).
- Styling: bg `bgElevated`, 1-pt `borderPopover`, radius 12, `shadowDialog`, padding 20, VStack gap 12:
  - title `dialogTitle`
  - body `body12Para` in `textSecondary`
  - buttons: right-aligned HStack gap 8, with 4 of top padding: [Cancel (regular secondary)] [Force Quit (regular destructive)]
- Esc means Cancel. There is no default button. Appears `.opacity` + scale 0.97→1, 0.15 s.
- Artboard: PRC.

### 2.27 Search field (`TTSearchField`)
- Height 28, width 220, horizontal padding 8, radius 7, `fillField`. HStack gap 6: `search` icon 14, then a text field in `body12` (text `textPrimary`, placeholder `textSecondary` "Search processes").
- No focus ring; the caret is `accent`. Filtering is live and case-insensitive over name, bundle ID and PID.

### 2.28 Treemap (ADDED; see §3.13)
- **Algorithm**: squarified treemap (Bruls, Huizing & van Wijk 2000). Sort the items descending by value, then lay out rows greedily along the shorter side of the remaining rectangle. Add an item to the current row while doing so moves the row's worst aspect ratio closer to 1; otherwise close the row. Values are normalized to the container area.
- **"Other"** aggregates apps under 2% share. It is always laid out **last**, so it lands in the bottom-right corner: run the algorithm on the named apps over the container minus Other's area, then place Other as the final strip. It is omitted when empty.
- **Gutter**: 2 pt between tiles. Implement it by insetting every computed tile rect by 1 pt on each side. The outer container edge therefore also has a 1-pt inset. Tile radius 4.
- **Fill**: the category color of the selected metric at @ 0.28. Hover raises it to @ 0.45.

| Metric | Color token |
|---|---|
| CPU | `cpu` |
| GPU | `gpu` |
| Memory | `mem` |
| Network | `net` |
| Disk | `disk` |
| Energy | `power` |

- The app that matches "Top process" gets a 1.5-pt inner stroke in the same color.
- **Label**, inset 8, top-left:
  - name `body12Strong` in `textPrimary`, tail truncation
  - value `caption` in `textSecondary` (for example "38% CPU")
  - The name is hidden if the tile is smaller than 60×28; the value is hidden if the tile is under 40 tall.
- The "Other" tile uses `fillTrack` (no category color) and the label "Other · {n} apps" in `caption` `textSecondary`, with no value line. It is not clickable.
- **Animation**: live updates (cursor at now, or the Live range) animate tile frames with `.easeInOut(duration: 0.25)`. The same applies to a metric change. While the user scrubs (slider or lane drag in progress), tiles update with **no animation**.
- Tooltip: "{name} · {value} · {share}%".
- Click: opens Processes with the app selected and its detail expanded.

### 2.29 Toggle, checkbox (ADDED, Settings)
- SwiftUI `Toggle(.switch)` with `.controlSize(.small)`, tinted `accent`. Checkboxes use `Toggle(.checkbox)` tinted `accent`.

---

## 3. Screens

### 3.0 Dashboard chrome (all dashboard artboards)

**Window**: 1280×860 by default, minimum 1100×720, resizable.
- Built as an `NSWindow` with `.fullSizeContentView`, a transparent titlebar, the title hidden, and an empty `NSToolbar` in style `.unified`. The unified toolbar gives a 52-pt titlebar, which makes the traffic lights center at y = 26. Their x positions come from the system; the design puts the first light at x = 18 with a gap of 8.
- The window corner radius and outline are native.
- Layout: HStack of the sidebar (220, fixed) and main (flex).

**Sidebar**: 220 wide including a 1-pt right `edgeSidebar`, bg `bgSidebar`, padding 0 top, 10 horizontal, 12 bottom.
1. A 52-tall traffic-light spacer.
2. The nav list, VStack gap 1:
   - section header `captionStrong` in `textTertiary`, padding 10 top, 10 horizontal, 4 bottom: **Monitor**
   - Overview (no value)
   - CPU: `{cpu}%`
   - GPU: `{gpu}%`
   - Memory: `{used} GB`
   - Network: `{down rate}`
   - Thermals: `{socAvg}°`
   - section header **System**
   - Power & Battery: `{package} W`
   - Disk: `{free} GB free`
   - section header **Activity**
   - Processes (no value)
   - History (no value)
   - The trailing values update at the sampling rate and show "—" when unavailable.
3. Flex spacer.
4. Device footer: 1-pt top `separator`, padding 12 top, 10 horizontal, 4 bottom, VStack gap 3:
   - `body12Strong`: model name, e.g. "MacBook Pro 14″" (`sysctl hw.model` mapped through a static model-name table)
   - `caption` `textSecondary`: "{chip} · {P}P + {E}E CPU · {n}-core GPU", e.g. "M4 Pro · 8P + 4E CPU · 16-core GPU". `{chip}` is `machdep.cpu.brand_string` with the leading "Apple " stripped; page-header subtitles keep the full "Apple M4 Pro". Other sources: `hw.perflevel0/1.physicalcpu`, and the GPU core count from IORegistry `AGXAccelerator` `gpu-core-count`)
   - `caption` `textSecondary`: "{RAM} GB unified memory · up {uptime}" (`hw.memsize`, `kern.boottime`)

**Page header**: height 52, bg `bgHeader`, 1-pt bottom `edgeHeader`, padding 0 16 0 20, HStack gap 10, center-aligned.
- Title block (flex, VStack): h1 `pageTitle`; sub `caption` in `textSecondary`.
- Trailing controls, in order: range `TTSegmented` (or the search field on Processes), then `iconButton` 28 Pause/Resume, then `iconButton` 28 Settings.
- Pause toggles global sampling. Its glyph becomes `play`, its tooltip becomes "Resume sampling", and the Overview subtitle becomes "Sampling paused".
- Settings opens the Settings window (§3.14).

**Content**: padding 20 on all sides, VStack gap 12. At the default size the inner width is 1020 and the inner height is 768. Named grids:
- `grid3`: 3 columns of `1fr`, gap 12, which gives 332 per column; `span 2` is 676. Chart widths inside: span-2 card ≈ 642, one-column card ≈ 298.
- `grid5`: 5 × `1fr`, gap 12, about 194 each.
- A typical page is a stat strip (about 82), `grid3` row(s), and a bottom table card with flex height.
- **Height rule**: every card and row height in §3 is a **minimum** (`.frame(minHeight:)`), never a fixed frame. The heights were recomputed from content using line height ≈ 1.2 × font size, padding 16 + 16 and 1 + 1 of border.
  - A `grid3` row is as tall as its tallest cell, and every card in the row stretches to that height.
  - Inside a stretched card, the **chart is the flex child**. It takes the extra height; text blocks never stretch.
  - The bottom table card takes whatever remains and scrolls its rows, so it shows fewer rows when the rows above grow.

**Range behavior**: Live means the last 60 s at 1-s samples. On History, Live also pins the cursor to now (§3.13). 1H, 24H, 7D and 30D read from the store (§5.10 lists the display buckets). Titles like "Last 60 seconds" follow the range ("Last hour", "Last 24 hours", "Last 7 days", "Last 30 days"). Tables always show live values; ranges only affect charts.

---

### 3.1 Menu bar popover, calm (MB)

**Container**: a borderless, non-activating `NSPanel`. Do not use `NSPopover`, because the design has no arrow.
- Width 360. Height is intrinsic: 478 calm, about 575 with a banner. Maximum height is the visible screen height minus 40; beyond that the row list scrolls.
- Styling: bg `bgPopover`, 1-pt `borderPopover`, radius 12, `shadowPopover`, padding 6.
- Position: top edge 8 below the menu bar, horizontally centered on the status item, clamped 8 from the screen edges.
- Closes on outside click, on Esc, or when the status item is clicked again.
- Open state: the status button shows a highlight (the design uses white @ 0.2, radius 4, height 22, and horizontal padding 5 around the 16-pt glyph). Use `button.highlight(true)`.

Elements, top to bottom:

| # | Element | Spec | Binding |
|---|---|---|---|
| 1 | Header | HStack gap 10, padding 8 top, 10 horizontal, 10 bottom. Glyph 20 (state-colored); VStack flex: "Telltale" `sectionTitle`, then an HStack gap 6 of a 7×7 dot and a status line in `caption` `textSecondary`; `iconButton` 26 Pause; `iconButton` 26 Settings | Status line (§3.2 rules): calm = `statusCalm` dot, "All systems nominal" |
| 2 | CPU row (full) | icon `cpu`; title "CPU"; sub "12 cores · 4.1 GHz"; sparkline 0–100; value `34%` | Core count from `hw.ncpu`. Frequency = P-cluster average active frequency from IOReport "CPU Stats"/"CPU Core Performance States" residency-weighted, 1 decimal GHz. Value = total CPU % from `host_processor_info` tick deltas, integer |
| 3 | GPU row | icon `gpu`; sub "1,180 MHz"; value `18%` | IOReport GPU residency-weighted frequency; GPU active residency % |
| 4 | Memory row | sub "pressure normal"; sparkline 0–RAM; value `15.1 GB` | Pressure level from `kern.memorystatus_vm_pressure_level` (normal / warning / critical, lowercase). Used = app + wired + compressed (`host_statistics64`) |
| 5 | Network row | sub "↑ 840 KB/s"; sparkline ↓ auto scale; value `12.4 MB/s` (↓) | `getifaddrs` byte deltas on the primary interface |
| 6 | Thermals row | sub "Nominal · 2,140 rpm"; sparkline 0–100 °C; value `62°C` | `ProcessInfo.thermalState` title-cased; average of fan RPM (SMC `F0Ac…`); SoC average from HID temperature sensors. No fans gives "Nominal · no fans" |
| 7 | Divider | 1 pt `separator`, margin 4 vertical, 10 horizontal | |
| 8 | Power row (compact) | icon `power`; "Power"; detail "82% · 5 h 40 m left"; value `18.6 W` | IOPowerSources percent and time remaining. Package W from IOReport Energy Model (CPU+GPU+ANE+DRAM+other). No battery gives detail "AC power" |
| 9 | Disk row (compact) | icon `disk`; "Disk"; detail "R 142 · W 38.0 MB/s" (CHANGED from the design's "W 38 MB/s" by the §5.4 rate rule); value `382 GB` | IOBlockStorageDriver `Statistics` deltas; free = `volumeAvailableCapacity` of "/" (`VolumeInfo.availableBytes`; purgeable never added — CP2 ruling) |
| 10 | Divider | as #7 | |
| 11 | Top consumer | HStack gap 10, padding 8×10: tile 26; VStack flex of "Top consumer" `caption` `textSecondary`, name `body13`, detail `caption` `textSecondary` "212% CPU · 3.8 GB"; small secondary "Quit" | App group with the highest CPU (libsysmon, grouped by responsible PID). Quit is disabled for non-user-owned apps |
| 12 | Divider | as #7 | |
| 13 | Footer | HStack gap 8, padding 6 top, 4 horizontal, 4 bottom: `popoverPrimary` "Open Dashboard" (flex); `popoverSecondary` "History"; ADDED `iconButton` 30×30 radius 7 bg `fillButton` with the `quit` glyph, tooltip "Quit Telltale" | Open Dashboard opens the window on Overview; History opens it on History; Quit calls `NSApp.terminate` |

Interactions:
- Row hover shows the top-apps flyout (§2.22).
- Row click (ADDED): opens the dashboard on that category page.
- Keyboard: ⌘Q quits Telltale. ⌘, opens Settings. ⌘D opens the Dashboard.

Popover row order and visibility come from Settings (§3.14). Hidden rows are removed entirely, and a divider is suppressed when either side of it is empty.

Sampling rate: 1 s while the popover is open (per SPEC).

### 3.2 Menu bar popover, thermal alert (MBA)

This is the same popover as §3.1, with these deltas:

| Element | Change |
|---|---|
| Header glyph | Thermals arc and center dot in `statusElevated` (§4) |
| Status line | `statusElevated` dot; text "Thermal pressure: Fair" |
| Banner (inserted after the header) | `TTAlertBanner` (§2.23). Text: "{App} is pushing the SoC to {T}°C. Performance cores may slow down to cool off." Buttons: [Show Thermals] opens the dashboard on Thermals; [Quit {App}] quits the app with the highest power (hidden when it is not user-owned) |
| Thermals row | bg `statusElevatedRowFill`; value `84°C` in `statusElevated`; sub "Fair · fans 3,900 rpm" |
| Top consumer | Shows the alert's culprit app. Detail: "96% CPU · 41% GPU". REMOVED: the activity word "· exporting" (no data source) |

**Alert rules** (built-in only, per ruling):

| Alert | Trigger | Severity | Stressed arc/row | Status-line text | Banner text |
|---|---|---|---|---|---|
| Thermal | `thermalState` = fair | elevated | Thermals | Thermal pressure: Fair | as above |
| Thermal | serious | elevated | Thermals | Thermal pressure: Serious | same template |
| Thermal | critical | critical | Thermals | Thermal pressure: Critical | same template |
| Memory | pressure level warning | elevated | Memory | Memory pressure: Warning | "Memory pressure is high. {App} is using {X GB}." [Show Memory] [Quit {App}] |
| Memory | critical | critical | Memory | Memory pressure: Critical | "Memory pressure is critical. {App} is using {X GB}." same buttons |
| Runaway app | one app ≥ 90% CPU (of one core) for ≥ 3 min while the popover is closed | elevated | CPU | Runaway app: {App} | "{App} has used {N}% CPU for {duration}." [Show Processes] [Quit {App}] |

- With several alerts, the status line shows the highest-severity one followed by " · +{n}". One banner is shown per alert, stacked with a gap of 6, most severe first.
- An alert clears when its condition has been false for 10 s.
- Critical uses the `statusCritical*` colors everywhere elevated uses amber.

### 3.3 Status icon (SI)

This artboard is reference only. The full spec is in §4. The captions are the source copy for §4's state table.

---

### 3.4 Overview (Main)

Header: h1 "Overview". Sub: "Sampling every second · all values live". The sub switches to "Sampling paused" when paused, and to "Showing last {range}" when the range is not Live. Controls: range, Pause, Settings.

Layout (768 tall):

| Row | Height | Grid |
|---|---|---|
| Metric tiles | 168 | `grid5` |
| Timeline + side cards | min 276 | `grid3`: timeline span 2; right column VStack gap 12 of Power (min 134) and Disk (min 120, flex: takes the rest, ≈130) |
| Top processes | flex (≈300) | full width |

Elements:

1. **Tiles** (§2.4), left to right:

| Tile | Value | Sub | Sparkline domain |
|---|---|---|---|
| CPU | `34` + `%` | "P 4.12 GHz · E 2.59 GHz" (IOReport per-cluster frequency) | 0–100 |
| GPU | `18` + `%` | "1,180 MHz · 3.1 GB" (frequency · system GPU memory in use from IOAccelerator `PerformanceStatistics` "In use system memory"; drop the "· 3.1 GB" segment if missing) | 0–100 |
| Memory | `15.1` + ` GB` | "of 24 GB · pressure normal" | 0–RAM |
| Network | `↓ ` + `12.4 MB/s` | "↑ 840 KB/s · Wi-Fi" (primary interface type: Wi-Fi / Ethernet / Thunderbolt Bridge / USB) | auto |
| Thermals | `62` + `°C` | "SoC avg · fans 2,140 rpm" | 0–100 |

   Clicking a tile navigates to its page.

2. **"Last 60 seconds" card**: card gap 12, min height 276. The design said 256; the content needs 34 + 20 + 12 + 186 (5 rows × 34 + 4 × 4) + 12 + 12 = 276. Rows keep 34; any extra height goes below the axis.
   - Header: title (it follows the range) and the link "Open History", which navigates to History.
   - 5 × `TTTimelineRow` (gap 4), for CPU, GPU, Memory, Network, Thermals. Values match the tiles; Network shows the ↓ rate.
   - Axis inset 96.

3. **Power card**: gap 10, min height 134 (the design said 122; content = 34 + 20 + 10 + 29 + 10 + 8 + 10 + 13).
   - Header: `power` icon, "Power", link "Details" (to Power).
   - An HStack with bottom alignment and space-between:
     - left: `title1` "18.6" + `title1Unit` " W package"
     - right: `body12` `textSecondary` HStack gap 6 of the `battery` glyph and "82% · 5 h 40 m left"
   - Split bar (§2.16).
   - Legend with values: "CPU 10.8 W", "GPU 4.1 W", "ANE 0.2 W", "DRAM 1.6 W".
   - Binding: IOReport Energy Model channels.

4. **Disk card**: gap 10, min height 120. It flexes to fill the column; extra height goes below the stats line.
   - Header: `disk` icon, "Disk", link "Details".
   - A space-between row in `body12`: "Macintosh HD" and "612 of 994 GB used" (`textSecondary`).
   - Medium bar, used fraction, in `disk`.
   - An HStack gap 16 in `body12` `textSecondary`: "Read 142 MB/s", "Write 38.0 MB/s", "382 GB free".

5. **Top processes card**: gap 8, flex.
   - Header: "Top processes", link "All processes".
   - Table template: `minmax(0,2.2fr) 1fr 1fr 1fr 1fr 1fr 28`.
   - Headers: Process | CPU | GPU | Memory | Network | Energy impact | (actions).
   - The rows are **app groups** (Apps mode, grouping rules in §3.12), sorted by CPU descending. Show as many as fit (≈4 at the default size).
   - Cells: `212.4%`, `0.4%`, `3.82 GB`, `—` or `100 KB/s` (CHANGED from the design's "0.1 MB/s" by §5.4), energy.
   - CHANGED: the energy cell shows average watts ("4.82 W"; §5.6) instead of the Energy Impact score.
   - Row click selects; double-click opens Processes with the app selected.

### 3.5 CPU

Header: h1 "CPU". Sub: "{chip} · {n} cores ({p} performance + {e} efficiency)".

| Row | Height | Grid |
|---|---|---|
| Stat strip (6) | ≈82 | 6 × 1fr |
| Cores | min 236 | `grid3`: P-cores span 2, E-cores 1 |
| Usage | min 196 | full width |
| Top CPU consumers | flex (≈218, about 3 rows visible; scrolls) | full |

1. **Stat strip**:

| Cell | Value | Sub | Binding |
|---|---|---|---|
| Total | `34%` in `cpu` color | "of 12 cores" | `host_processor_info` |
| User | `22.1%` | — | user ticks |
| System | `11.9%` | — | system ticks |
| Idle | `66.0%` | — | idle ticks |
| Load average | `3.21 · 2.88 · 2.54` | "1 · 5 · 15 min" | `getloadavg` |
| Threads | `3,104` | "in 612 processes" | libsysmon thread counts / `proc_listallpids` |

2. **Performance cores card**: gap 12, min height 236. The design said 228; content = 34 + 22 (header with a 22-tall badge) + 12 + 143 (bar column: 14 + 6 + 104 + 6 + 13) + 12 + 13. The bar track stays 104; extra height goes below the footer.
   - Header: "Performance cores" plus badge "8 cores" with a `cpu` dot.
   - `TTCoreBars` with 8 columns (per-core % from `host_processor_info`). Map core IDs to clusters with `hw.perflevel0/1.logicalcpu`: on Apple Silicon the E-cores come first in logical order, so confirm this in the M0 spike.
   - Footer: "4.12 GHz of 4.51 GHz" (current P-cluster frequency of the maximum DVFS state, from IORegistry `pmgr` voltage-states), "Active residency 58%" (IOReport cluster residency), "Cluster power 8.9 W" (IOReport energy per cluster; "—" if absent).
3. **Efficiency cores card**: the same, with badge "4 cores" and a `cpuAlt` dot, 4 columns, and footer "2.59 GHz of 2.89 GHz", "Active residency 29%". CHANGED: the design's label "Residency" is unified to "Active residency".
4. **Usage card**: gap 10, min height 196. The design said 192; content = 34 + 20 + 10 + 110 + 10 + 12.
   - Header: "Usage" and legend [User `cpu`] [System `cpuAlt`].
   - `TTStackedArea` (full width × 110, the flex child), then the axis.
5. **Top CPU consumers**: gap 8.
   - Header: title and link "All processes".
   - Template: `minmax(0,2fr) 70 110 80 90 70 170`.
   - Headers: Process | PID (right) | User (left) | % CPU (right) | CPU time (right) | Threads (right) | (actions).
   - Rows are individual **processes**, sorted by % CPU. As many as fit are shown; the rest scroll.
   - Cells: `1842`, `arthur` (`textSecondary`), `212.4`, `2:41:07`, `86`.
   - A selected row shows inline [Quit] [Force Quit].

### 3.6 GPU

Header: h1 "GPU". Sub: "{chip} · {n}-core GPU · {n}-core Neural Engine". The ANE core count comes from a static chip table and is omitted if unknown.

| Row | Height | Grid |
|---|---|---|
| Stat strip (5) | ≈82 | 5 × 1fr |
| Charts | min 293 with Media engines (ANE 138 + 12 + Media 143); min 250 without | `grid3`: Utilization span 2; right column VStack gap 12 of ANE and Media engines |
| GPU clients | flex (≈369 with Media, ≈412 without) | full |

1. **Stat strip**:
   - Utilization: `18%` in `gpu`, sub "active residency" (IOReport GPU Stats)
   - Frequency: `1,180 MHz`, sub "of 1,578 MHz" (maximum from the GPU DVFS table)
   - GPU power: `3.4 W` (IOReport)
   - GPU memory: `3.1 GB`, sub "allocated from unified memory" (IOAccelerator "In use system memory"; "—" with tooltip if absent). This is system-level, so it is kept.
   - Cores: `16`
2. **Utilization & frequency card**: gap 10, stretches to the row height (content minimum 246).
   - Header legend: [Utilization `gpu`] [Frequency `gpuAlt`].
   - `TTDualChart`, then the axis. The chart is the flex child: at least 160 tall, about 207 when the row is 293.
3. **Neural Engine card**: gap 6, min height 138 (the design said 119; content = 34 + 22 + 6 + 26 + 6 + 44). CHANGED per ruling: watts only.
   - Header: "Neural Engine" plus badge "16 cores" with a `power` dot.
   - HStack with baseline alignment and space-between:
     - `title2` "0.2 W" (ANE power from IOReport)
     - right side, `body12` `textSecondary`: "idle" when under 0.05 W, otherwise "active"
   - REMOVED: the "{aneNow}%" value.
   - Sparkline (fill × 44) of ANE watts, auto scale (§5.10), in `power`.
4. **Media engines card**: padding 14, gap 7, min height 143 (the design said 119; content = 30 + 20 + 3 × (7 + 24)). Kept **only if IOReport exposes media-engine residency**.
   - Header "Media engines".
   - 3 rows, each a VStack gap 5: a space-between line in `body12` (name, then value in `textSecondary`), then a thin bar in `gpu`.
   - Rows: "Video encode", "Video decode", "ProRes engine". Values: `22%` or "idle" when 0.
   - REMOVED: the codec suffix "· HEVC" (no source).
   - If media-engine data is unavailable, **REMOVE the card**; the ANE card then fills the right column. The row is 250 tall and the sparkline flexes to 250 − 94 = 156.
5. **GPU clients**:
   - Header: title and link "All processes".
   - CHANGED template: `minmax(0,2fr) 80 90 28`.
   - Headers: Process | % GPU | GPU time | (actions).
   - REMOVED: the Renderer column and the Memory (per-app GPU memory) column.
   - Rows are app groups from AGXDeviceUserClient `accumulatedGPUTime` deltas. % GPU is delta GPU time divided by wall time, 1 decimal. GPU time is the cumulative time since the app launched (§5.8).

### 3.7 Memory

Header: h1 "Memory". Sub: "24 GB unified memory · LPDDR5X · 273 GB/s". RAM comes from `hw.memsize`; the memory type and bandwidth come from a static chip table, and the segments are omitted if unknown.

| Row | Height | Grid |
|---|---|---|
| Stat strip (5) | ≈82 | 5 × 1fr |
| Composition | intrinsic ≈131 | full |
| Charts | 240 | `grid3`: Pressure span 2; Swap 1 |
| Top memory consumers | flex (≈283) | full |

1. **Stat strip**:
   - Used: `15.1 GB` in `mem`, sub "of 24 GB"
   - Memory pressure: `38%`, sub "Normal" (level word colored: Normal `textTertiary`, Warning `statusElevated`, Critical `statusCritical`). The % is `100 − kern.memorystatus_level`.
   - Swap used: `1.20 GB`, sub "of 2.00 GB allocated" (`vm.swapusage`)
   - Compressed: `2.4 GB`, sub "ratio 2.8 : 1" (compressor pages vs. compressed-in-use; `host_statistics64`)
   - Page-ins · outs: `412 · 0`, sub "per second"
2. **Composition card**: gap 12.
   - Header: "Composition" plus a `body12` `textSecondary` caption "24.0 GB unified memory".
   - Composition bar (§2.16).
   - A legend grid of `repeat(5,1fr)` with gap 12. Each cell is a VStack gap 2: swatch and label in `caption` `textSecondary`, then the value in `pageTitle` weight (15/600).
   - Order: App memory, Wired, Compressed, Cached files, Free.
3. **Memory pressure card**: gap 10, height 240.
   - Legend: [Normal `mem`] [Warning `statusElevated`] [Critical `statusCritical`]. CHANGED copy: "Warning ≥ 60%" / "Critical ≥ 80%" become "Warning" / "Critical", because the color follows the OS level rather than fixed % thresholds.
   - Area chart 0–100 (fill × 150, the flex child). Color by the OS pressure level: the span from sample *i* to *i+1* takes the level of sample *i*. The color therefore changes exactly at the first sample reporting the new level. Line and fill switch together, with no gradient or blending across the change.
   - Axis.
4. **Swap card**: gap 8, height 240.
   - Header: "Swap", then trailing `title2` "1.20 GB" + `title2Unit` " of 2.00 GB".
   - Sparkline (fill × 50), domain 0–allocated, in `memCompressed`.
   - Key-value list: "Swap-ins" `0 / s`; "Swap-outs" `0 / s`; "Swap files" `2` (count of `/System/Volumes/VM/swapfile*`).
5. **Top memory consumers**:
   - CHANGED template: `minmax(0,2fr) 90 28`.
   - Headers: Process | Memory | (actions).
   - REMOVED unconditionally (architecture ruling): the Compressed, Private and Ports columns.
   - Rows are app groups sorted by memory; as many as fit, and the rest scroll.
   - Memory is the phys footprint (`proc_pid_rusage` `ri_phys_footprint`). Coalition-only root rows show "—" (§3.12).

### 3.8 Network

Header: h1 "Network". CHANGED sub: "Wi-Fi 6E · 5 GHz · 1,201 Mbps link". REMOVED: the SSID "Studio 5G".
- PHY mode comes from CoreWLAN `activePHYMode` (802.11ax, mapped to "Wi-Fi 6/6E" by band), the band from `wlanChannel.channelBand`, and the link from `transmitRate`.
- For Ethernet: "Ethernet · {speed} link" (from `ifi_baudrate`).

| Row | Height | Grid |
|---|---|---|
| Stat strip (5) | ≈82 | 5 × 1fr |
| Charts | 268 | `grid3`: Throughput span 2; Interfaces 1 |
| Network by app | flex (≈396) | full |

1. **Stat strip**:
   - Download: `12.4 MB/s` in `net`, sub "Wi-Fi · en0"
   - Upload: `840 KB/s`, sub "Wi-Fi · en0"
   - Today: `↓ 8.4 GB · ↑ 1.1 GB` (store: sum since local midnight)
   - Latency: `18 ms`, sub "to 192.168.1.1" (unprivileged ICMP `SOCK_DGRAM` to the router every 10 s; median of the last 3)
   - Packet loss: `0.0%`, sub "last 5 minutes" (lost / sent pings over 5 min)
2. **Throughput card**: gap 10, height 268.
   - Legend: [Download · scale {N}] [Upload · scale {N}].
   - `TTMirroredChart` 2 × 90 (↓ on top, ↑ below), then the axis.
3. **Interfaces card**: gap 8, height 268.
   - Primary interface block: VStack gap 4, 8 of bottom padding, 1-pt bottom `separator`.
     - Space-between row: "Wi-Fi · en0" `sectionTitle`, badge "Active" (`statusCalm` dot).
     - Detail line in `caption` `textSecondary`: CHANGED "5 GHz · channel 149 · −52 dBm · 1,201 Mbps". REMOVED: the SSID.
   - Each other interface is a row, space-between, 4 bottom padding: name in `body13` `textSecondary` ("Thunderbolt Ethernet · en5"); state in `caption` `textTertiary` ("Not connected"). List up to 2 inactive hardware ports.
   - Key-value list: "Local IP" `192.168.1.24` (mono11); "Router" `192.168.1.1` (mono11, from the routing table default gateway).
   - REMOVED: the "Public IP" row and its [Reveal] button.
4. **Network by app**:
   - Template: `minmax(0,2fr) 100 100 110 90 28`.
   - Headers: Process | Download | Upload | This session | Connections | (actions).
   - Rows are app groups from NetworkStatistics.framework. "This session" is the bytes ↓+↑ since Telltale started. Connections is the count of live flows.
   - Sorted by ↓+↑ descending, 5 visible.

### 3.9 Thermals

Header: h1 "Thermals". Sub: "SoC sensors, fans and macOS thermal pressure".

| Row | Height | Grid |
|---|---|---|
| Stat strip (4) | ≈82 | 4 × 1fr |
| Thermal pressure | intrinsic ≈109 | full |
| Charts | 244 | `grid3`: Temperatures span 2; Fans 1 |
| Sensors | flex (≈299) | full |

1. **Stat strip**:
   - SoC average: `62°C` in `thermal`, sub "12 sensors" (count of SoC die sensors in the average)
   - Hottest sensor: `74°C`, sub "P-core cluster, die 3" (sensor display name)
   - Thermal pressure: `Nominal`, colored by level (Nominal `statusCalm`, Fair `statusFair`, Serious `statusElevated`, Critical `statusCritical`). Sub: "no throttling" / "mild fan boost" / "clock limiting likely" / "heavy throttling"
   - Fans: `2,140 · 2,210`, sub "rpm". CHANGED sub: the design's "rpm · automatic" becomes "rpm", because fan mode is read-only. With one fan the value is one number. With no fans the value is "—" and the tooltip is "This Mac has no fans".
2. **Thermal pressure card**: gap 10.
   - Header caption: "Reported by macOS · changes are logged to History".
   - `thermalScale` (§2.16) with levels Nominal, Fair, Serious, Critical, described as "Full performance", "Mild fan boost", "Clock limiting likely", "Heavy throttling".
3. **Temperatures card**: gap 10, height 244.
   - Legend: [P-cores `thermal`] [GPU `thermalGPU`] [Battery `thermalBattery`].
   - `TTLineChart` with y-labels 105°/89°/72°/56°/40° (domain 40–105 °C) and height 150.
   - Series: P-core average, GPU average, battery (IOHID sensors, grouped per SPEC).
   - Axis inset 34.
4. **Fans card**: gap 12, height 244.
   - Header: `fan` icon 16 in `thermal`, stroke 1.5, then "Fans".
   - One `TTFanGauge` row per fan (HStack gap 14), labeled "Left fan" / "Right fan" (or "Fan" when there is one). Max comes from SMC `F{n}Mx`.
   - REMOVED: the Fan mode group [Automatic] [Full speed] (fans are read-only).
   - No fans: the card body shows the centered empty state "This Mac has no fans" (§3.15).
5. **Sensors card**: gap 6.
   - Header caption: "{g} groups · {n} raw sensors".
   - Template: `minmax(0,2fr) 70 80 minmax(0,2fr)`.
   - Headers: Sensor | Now (right) | Peak (1 h) (right) | (bar, left).
   - Rows are 28 tall. Name cell: HStack gap 8 of the name in `body12` and a detail in `caption` `textTertiary` ("avg of 8", "PMU die", "NAND", "cell avg", "left intake").
   - Now is `66°C` in `textPrimary`. Peak is `74°C` in `textSecondary`, the maximum over the last hour from the store. The bar is thin, in `thermal`, width `(t − 20) / 85` clamped to 0…1 (a 20–105 °C scale).
   - Groups: CPU performance cores, CPU efficiency cores, GPU cluster, SoC package, SSD, Battery, Airflow. A group missing on a given Mac is omitted.
   - ADDED (per SPEC): the header gets a trailing link "Show raw sensors". It expands the table, grouped, with child rows of 28 at indent 20 listing every raw HID sensor. Clicking a raw sensor row toggles an inline sparkline strip (fill × 30, 1H history) under it.

### 3.10 Power & Battery

Header: h1 "Power & Battery". Sub: "On battery · 72.4 Wh · Low Power Mode off".
- The first segment is "On battery" or "On power adapter · {W} W" (IOPowerSources).
- Design capacity comes from AppleSmartBattery `DesignCapacity`×`Voltage`.
- `ProcessInfo.isLowPowerModeEnabled` gives the last segment.

| Row | Height | Grid |
|---|---|---|
| Stat strip (6) | ≈82 | 6 × 1fr |
| Charts | min 285 | `grid3`: Power by component span 2; Battery 1 |
| Energy impact | flex (≈377) | full |

1. **Stat strip**:
   - Package: `18.6 W` in `power`, sub "SoC total"
   - CPU: `10.8 W`
   - GPU: `4.1 W`
   - Neural Engine: `0.2 W`
   - DRAM: `1.6 W`
   - Battery drain: `−18.9 W`, sub "system total" (AppleSmartBattery `InstantAmperage` × `Voltage`; on the adapter it shows `+{W} W` charging or `0.0 W`)
2. **Power by component card**: gap 10, stretches to the row height (285).
   - Legend: CPU, GPU, ANE, DRAM.
   - `TTStackedArea`, then the axis. The chart is the flex child: at least 160 tall, about 199 at a row height of 285.
3. **Battery card**: gap 8, min height 285. The design said 262; content = 34 + 20 + 8 + 42 (title1 29 + caption 13) + 8 + 173 (6 key-value rows × 28 + 5 rules).
   - Header: `battery` icon, then "Battery".
   - HStack gap 14:
     - large battery glyph: 84×38, radius 9, 2-pt border white @ 0.4, padding 3; inner fill radius 5 in `battery`, width = charge %. The fill turns `statusElevated` at ≤ 20% and `statusCritical` at ≤ 10% (ADDED).
     - VStack: `title1` "82%", then `caption` `textSecondary` "On battery · about 5 h 40 m left" or "Charging · full in 1 h 10 m".
   - Key-value list:
     - Health: "94% maximum capacity" (`NominalChargeCapacity`/`DesignCapacity`)
     - Condition: "Normal"
     - Cycle count: `212`
     - Capacity: "68.1 of 72.4 Wh"
     - Temperature: `31°C`
     - Power adapter: "Not connected" or "{W} W USB-C"
   - Desktop Mac without a battery: the card shows the empty state "No battery".
4. **Energy impact table**:
   - Header: title and link "All processes".
   - CHANGED template: `minmax(0,2fr) 110 100 120 170`.
   - Headers: Process | Energy impact (right) | 12 h average (right) | Preventing sleep (left) | (actions).
   - Rows are **app groups**, expandable into their processes exactly as in Processes Apps mode (§3.12: disclosure slot, 30-pt child rows).
   - Values are **average watts**: per-process `ri_energy_nj` deltas (`proc_pid_rusage` `RUSAGE_INFO_V6`) divided by wall time, summed per app. Root processes add their coalition residual.
   - Values that include a coalition residual or an estimate carry a `.help("Estimated")` tooltip and are otherwise styled the same.
   - Examples: "7.15 W" now, and the 12 h average from the store.
   - REMOVED: the App Nap column.
   - Preventing sleep: "Yes" in `statusElevated` or "No" in `textSecondary` (`IOPMCopyAssertionsByProcess`).
   - A selected row shows inline [Quit] [Force Quit].

### 3.11 Disk

Header: h1 "Disk". Sub: "Apple SSD · 1 TB · PCIe" (IORegistry NVMe controller model, capacity and transport).

| Row | Height | Grid |
|---|---|---|
| Stat strip (4) | ≈82 | 4 × 1fr |
| Volumes | intrinsic ≈131 | full |
| Charts | min 247 | `grid3`: Throughput span 2; SSD health 1 |
| Disk activity by process | flex (≈274) | full |

1. **Stat strip**:
   - Read: `142 MB/s` in `disk`, sub "3.4k IOPS"
   - Write: `38.0 MB/s`, sub "0.9k IOPS" (IOBlockStorageDriver `Statistics` operations/bytes deltas)
   - Free space: `382 GB`, sub "on Macintosh HD"
   - SSD wear: `2% used`, sub "48.2 TB written" (NVMe SMART percentage used and data units written; "—" plus tooltip "SMART data unavailable without root" if absent)
2. **Volumes card**: gap 12.
   - A 2-column grid, gap 32. Each volume is a VStack gap 8:
     - HStack gap 10: the `disk` icon at 18, then a flex VStack of name `sectionTitle` and detail `caption` `textSecondary` ("Internal · APFS · encrypted" / "USB-C · APFS · 1,050 MB/s link"), then usage in `body12` `textSecondary` ("612 GB of 994 GB"), then an eject button (`iconButtonFilled` 26, `eject` 14) for removable volumes only.
     - Volume bar: used, then purgeable.
   - Legend: [Used] [Purgeable].
   - Show up to 2 volumes; beyond 2, the grid wraps to more rows. Eject calls `NSWorkspace.unmountAndEjectDevice`.
3. **Throughput card**: gap 10, min height 247. The design said 236; content = 34 + 20 + 10 + 161 (80 + 1 + 80) + 10 + 12.
   - Legend: [Read `disk`] [Write `diskWrite`] [scale {N} MB/s].
   - `TTMirroredChart` 2 × 80 with a shared scale (the halves are the flex children and split any extra height equally), then the axis.
4. **SSD health card**: gap 6, stretches to the row height (content 235).
   - Header: "SSD health" plus a badge "Healthy" (`statusCalm`), "Worn" (`statusElevated`, percentage used ≥ 80), or "Failing" (`statusCritical`, SMART critical warning ≠ 0).
   - Key-value list: Percentage used `2%`; Data written `48.2 TB`; Data read `61.7 TB`; Temperature `41°C`; Power-on hours `3,412`; Unsafe shutdowns `3`.
   - Per ruling: only what the NVMe SMART IOKit plugin gives without root. If SMART is unavailable, the list collapses to one row "Status: Verified" (from DiskArbitration/IOKit `SMART Status`), and the badge reflects that status only.
5. **Disk activity by process**: no header link.
   - Template: `minmax(0,2fr) 100 100 110 120 28`.
   - Headers: Process | Read | Write | Read (session) | Written (session) | (actions).
   - Rows are 32 tall and are **processes** (the design lists mds_stores), from `ri_diskio_bytesread/written` deltas. Session totals count since Telltale launched.

### 3.12 Processes

Header: h1 "Processes". Sub: "612 processes · 3,104 threads · select a row to inspect". Controls: search field (220), Pause, Settings. There is no range control.

Layout: a list card (flex) above the inspector card. The two are separated by a gap of 12.

**List card** (padding 16, gap 12):

1. **Toolbar row**: HStack gap 12, center-aligned.
   - ADDED: `TTSegmented` [Apps | Processes], default Apps.
   - `body12` `textSecondary` "Sort by".
   - `TTSegmented` [CPU | GPU | Memory | Network | Disk | Energy].
   - Flex spacer. The toast goes in the spacer: `body12` `textSecondary` "{name} quit." / "{name} was force quit.", auto-dismissed after 4 s. REMOVED: the "Undo demo" button (demo only).
   - Count in `body12` `textSecondary`: Apps mode "{n} apps · 612 processes"; Processes mode "{n} of 612 shown".
2. **Header row**: template `minmax(0,2.2fr) 64 110 70 64 84 84 84 70`, height 28.
   - Headers: Process | PID (right) | User (left) | % CPU | % GPU | Memory | Network | Disk | Energy (right-aligned numerics).
   - Clicking a numeric header also sets the sort (ADDED); the active sort header is `textPrimary` with the `chevronDown` icon at 10 pt.
3. **Rows**: height 34, gap 1, zebra, `rowSelected` for the selection. Cells:
   - Name cell: in Apps mode (ADDED), a 12-wide disclosure slot with `chevronRight` 10 (rotated 90° when expanded, `.easeInOut(0.15)`), then a gap of 6. Then tile 20, the name (tail truncation), and the kind label in `caption` `textTertiary` ("App", "System", "Background"). In Apps mode the kind label becomes "App · 7 processes".
   - PID: responsible PID for an app group.
   - User: `textSecondary`.
   - `212.4` (CPU, no % sign because the header has one), `9.2`, `3.82 GB`, `100 KB/s` (CHANGED from the design's "0.1 MB/s", §5.4) or `—`, `22.4 MB/s` or `—`, and energy as "7.15 W" (CHANGED from the score; §5.6).
   - Group values are sums over the child processes.
4. **App grouping** (ADDED). Rows are formed in this order:
   1. **App group**: every process whose responsible PID (`responsibility_get_pid_responsible_for_pid`) resolves to an app bundle joins that app's group. The group is named by the app. For example, `com.docker.backend` groups under **Docker Desktop** and is not its own row. Fallback: the bundle path of the executable.
   2. **Standalone daemon**: a process with no bundle that is responsible for itself becomes **its own group**, named by its process name. For example, `WindowServer` and `mds_stores` stay single rows with kind "System" or "Background".
   3. **Coalition row**: an unattributable root process (no readable responsible PID or path without root) that belongs to a coalition becomes a row with provenance `.coalition`, named by the coalition leader's `p_comm` and with kind "System".
      - Its CPU and energy come from the coalition's resource usage (energy is marked "estimated", §3.10).
      - Its Memory cell shows "—" with the tooltip "Requires root · updated when Processes is open". This holds until the `ps` RSS fallback (run only while Processes is visible) delivers a value; the cell then shows that value.
      - PID and User show the leader's PID and "root".
   4. **"System"**: anything left over (no responsible PID, no coalition) is summed into one "System" row.
   - The design's sample rows (Xcode, Final Cut Pro, Safari, WindowServer, com.docker.backend) mix rules 1 and 2. They were illustrative; under these rules the Docker row reads "Docker Desktop".
   - This Apps-mode expansion is what satisfies SPEC's per-app "process list". The App detail does not repeat it.
   - Expanding a group inserts child rows, 30 tall:
     - disclosure slot empty
     - 16-pt tile, indented so the child name starts 28 right of the parent name
     - name `body12`, kind hidden
     - all other columns are the process's own values in `textSecondary`
   - Child rows share the parent's zebra parity and do not alternate on their own.
5. Keyboard:
   - ↑/↓ moves the selection.
   - ←/→ collapses or expands a group.
   - Return toggles the inspector detail.
   - ⌘⌫ asks to force quit.
   - ⌘F focuses search.

**Inspector card**, collapsed (the design): padding 16, HStack gap 20, center-aligned, height about 78.
1. Tile 44.
2. Identity VStack gap 3, width 300:
   - name `pageTitle`
   - path in `mono11` `textSecondary`, **middle** truncation (CHANGED from tail; §6)
   - "PID 2210 · arthur · 64 threads" in `caption` `textTertiary`. For a group: "PID {responsible} · {user} · {n} processes".
3. Stats grid: `repeat(4,1fr)`, gap 16, flex. Each cell is a VStack gap 2 of a `caption` `textSecondary` label and a value in 15/600:
   - CPU `96.1%`
   - GPU `9.2%`
   - Memory `5.10 GB`
   - Energy: CHANGED to watts, "7.15 W"
4. Buttons, HStack gap 8:
   - [Sample] (regular secondary): runs `/usr/bin/sample {pid} 3 -file …` in the background and opens the report in Console. Disabled for non-owned processes.
   - [Quit] (regular secondary)
   - [Force Quit…] (regular destructive)
   - ADDED: `iconButton` 28 `ellipsis` opens the row actions menu (§2.25)
   - ADDED: `iconButton` 28 `chevronDown` / `chevronRight`, which toggles detail. Tooltip "Show details" / "Hide details". Double-clicking a row also toggles detail.
   - For non-owned processes, Quit and Force Quit are disabled (opacity 0.4) with the tooltip "Owned by {user}".

**Inspector expanded: App detail** (ADDED per ruling):
- The card grows to min 391 tall (78 + 33 + 280) with `.easeInOut(0.2)`. The list card shrinks; about 7 rows stay visible at the default size, never fewer than 5.
- Below the collapsed content: a 1-pt `separator` with 16 above and 16 below, then a body of **min 280** laid out as `grid` 2 × 1fr with gap 24. The left column needs 24 + 10 + 224 + 10 + 12 = 280. The connections table is the flex child.
- **Left, Activity**:
  - `TTCardHeader`-style row (24 tall): "Activity" `sectionTitle`, then a **compact** `TTSegmented` (§2.13) [Live 1H 24H 7D 30D] (default Live). Gap 10 to the rows.
  - 6 × `TTTimelineRow` (gap 4) with 30-tall sparklines: CPU (% of one core, auto scale ≥ 100), GPU, Memory, Network (↓+↑), Disk (R+W), Energy (W).
  - Values are this app's current values. Historical ranges read the per-app store rows (apps under the threshold count toward `other` and show a gap).
  - Gap 10, then the axis (inset 96).
- **Right, "Live connections"** (count in the title, e.g. "Live connections · 14"):
  - Table template `minmax(0,1fr) 52 48 72 72`, header 26, rows 28, scrolling past 7 rows.
  - Headers: Remote host | Port (right) | Proto (left) | ↓ (right) | ↑ (right).
  - Remote host: the reverse-DNS name in `body12`, or the IP in `mono11` while unresolved. Resolve asynchronously; never block.
  - Proto: "TCP" or "UDP" in `caption` `textSecondary`.
  - Rates are per flow from NetworkStatistics.
  - Live only, never persisted; this is not affected by the range control.
  - Empty: "No open connections". Not running: "Not running".
- In Processes mode, detail shows the process instead of the group, and connections are filtered to its PID.

**Force-quit dialog**: §2.26.
- Title "Force quit “{name}”?". Body "Unsaved changes will be lost. The process ends immediately without cleanup."
- Force Quit → `forceTerminate()` (app) / `kill(pid, SIGKILL)`. The row disappears and the toast shows.

Sampling: 1 s while the window is visible.

### 3.13 History

Header: h1 "History". Sub: "Stored locally · {bucket} resolution for {range} · kept for 30 days". The buckets are 1H → "15-second", 24H → "5-minute", 7D → "30-minute", 30D → "2-hour", so the design copy is reproduced exactly at 24H. Live → "1-second resolution for 60 s". Controls: range `Live 1H 24H 7D 30D` (CHANGED per ruling: Live added; 24H is the default), Settings. There is no Pause button (as designed).

**Live on History** (ruling): Live shows the last 60 s at 1-s buckets and **pins the cursor to now**. Each new sample moves the window, the cursor stays on the newest bucket, and the treemap updates every second.
- Dragging the cursor or the slider unpins it. The "At" badge "Live" disappears while unpinned.
- Returning the cursor to the newest bucket, or re-selecting Live, re-pins it.
- On the other ranges, the cursor starts at the latest bucket but is not pinned, because stored ranges do not advance per second.

Layout: the timeline card (intrinsic, about 507), then the "At" card (flex, about 249).

**Timeline card** (gap 10):
1. Header: the title is the range label ("Last 60 seconds" for Live, "Thursday, 24 September" for 24H, "Last hour" for 1H, "18 – 24 September" for 7D, "26 August – 24 September" for 30D). Trailing legend: [Thermal pressure: Fair] with swatch `statusElevatedSwatch`. Add legend items only for band types present in the range: Fair (amber), Serious (amber, band opacity 0.22), Critical (red), Memory pressure (amber), Paused (`fillTrack`).
2. Body: HStack gap 8.
   - **Label column**, 170 wide:
     - "Events" row: 30 tall, `body12` `textSecondary`, 1-pt bottom `separator`.
     - 6 lane labels, each 58 tall, VStack centered, gap 2, 1-pt bottom `separator`:
       - line 1: icon 14 + name in `body12` `textSecondary`, gap 7
       - line 2: the value at the cursor in `pageTitle` 15/600, left padding 21
     - Lanes and values: CPU `%`; GPU `%`; Memory pressure `%`; Network ↓ as a rate, following the §5.4 bands (`840 KB/s`, `12.4 MB/s`, `142 MB/s`); SoC temperature `°C`; Package power `W`.
   - **Chart column**, fill (810 in the design):
     - Event row, 30 tall: chips (§2.14 `chip`), absolutely positioned and centered at the event's x, top 4. Label "{title} · {HH:mm}", e.g. "Xcode build · 14:30". Click a chip to move the cursor there.
       - Event sources: thermal/memory alerts start ("Thermal: Fair"), runaway app ("{App} CPU spike"), sampling paused/resumed, and swap growth ≥ 1 GB within 30 min ("Swap +2.1 GB").
       - Titles come from the culprit app. Overlapping chips: keep the one with higher severity and hide the others behind a "+{n}" chip.
     - 6 lanes, each 58 tall with a 1-pt bottom `separator`: sparkline 48 tall, bottom-aligned, bottom padding 2. Domains: CPU 0–100, GPU 0–100, Memory 0–100, Network 0–auto, Temp 35–100, Power 0–auto.
     - Bands: absolute from y 30 to the bottom, x/width from the event interval, solid `#FFB340` at opacity 0.14 (critical: `#FF453A` 0.14). Paused intervals: `fillTrack` plus a centered `micro` label "Paused" in `textTertiary` if 40 or more wide.
     - Cursor: absolute over the full height (0 to the bottom), 1.5 wide, `textPrimary` @ 0.85. Drag anywhere on the lanes to scrub (ADDED; the design only has the slider).
3. Axis row, inset 178 (§2.12).
4. Scrubber, inset 178, VStack gap 4: `caption` `textSecondary` "Scrub timeline", then an `NSSlider` spanning the chart width, tinted `accent`. Range 0…(bucket count − 1) with integer steps: max 287 for 24H (288 buckets) and 59 for Live.
   - The ← and → keys step one bucket.
   - The default position is the latest bucket ("now"). In Live it is pinned (see above).

**"At" card**: CHANGED to hold the time-travel treemap (ADDED per ruling). Padding 14×16, HStack gap 24, `aria-live` (`.accessibilityAddTraits(.updatesFrequently)`).
1. **Left column**, 220 wide, VStack gap 10:
   - "At" `caption` `textSecondary`, then `title2` "14:35". When the cursor is at the latest bucket, show "Now" plus a badge "Live" (`statusCalm` dot).
   - "Top process" `caption` `textSecondary`, then `dialogTitle` "Xcode · 812% CPU": the top app by the treemap metric at the cursor.
   - A note in `body12Para` `textSecondary`, at most 3 lines, generated from events overlapping the cursor, e.g. "CPU spike from an Xcode build. SoC reached 88°C; thermal pressure went to Fair." With no events: "Nothing unusual in this window."
   - Flex spacer.
   - [Export CSV] (regular secondary): saves via `NSSavePanel` the system totals of the current range at display resolution. Columns: `timestamp_iso8601,cpu_pct,gpu_pct,mem_pressure_pct,net_down_Bps,net_up_Bps,soc_temp_c,package_w`.
2. **Treemap column**, flex, VStack gap 8:
   - Header row: "App share" `sectionTitle` (flex), then a **compact** `TTSegmented` (§2.13) [CPU | GPU | Memory | Network | Disk | Energy] (default CPU).
   - `TTTreemap` (§2.28) fills the rest (about 760 × 190).
   - Data: the per-app rows of the bucket under the cursor, grouped by the §3.12 rules. When pinned at now it updates every 1 s from live samples.
   - Animation: per §2.28, 0.25 s ease-in-out for live updates and metric changes, and none while scrubbing.
   - Empty bucket (paused or no data): the centered message "No data for this moment".

### 3.14 Settings window (ADDED)

- `NSWindow` titled "Settings", 520 wide with intrinsic height (about 540), not resizable, same chrome as the dashboard (52-pt unified titlebar). The body bg is `bgWindow`.
- The title is rendered in the header strip: `bgHeader`, 1-pt bottom `edgeHeader`, `pageTitle` "Settings" at x = 80 (clear of the traffic lights).
- Content padding 20, VStack gap 16. Sections are a header (`captionStrong` `textTertiary`, padding 0 4 6) over a card with no padding.
- Card rows are 36 tall, horizontal padding 16, `body13` label on the left, control on the right. There is a 1-pt `separator` between rows, inset 16 from the leading edge.

| Section | Rows |
|---|---|
| General | "Launch at login": switch (`SMAppService.mainApp` register/unregister; reflects `.status`, and shows `caption` `textTertiary` "Requires approval in System Settings" under the label when `.requiresApproval`) |
| Units | "Temperature": `TTSegmented` [°C | °F]. "Network rates": `TTSegmented` [Bytes/s | Bits/s] |
| Popover | 7 rows, 32 tall: `dragHandle` 16, category icon 16, name `body13` (flex), visibility checkbox. Drag to reorder (`onMove`), persisted to UserDefaults `popover.rows` as an ordered array of `{id, visible}`. At least one row must stay visible; the last visible checkbox is disabled |
| About | Row, `caption` `textSecondary`: "Telltale {version} ({build})". Row: "History: {size} on disk · kept 30 days" |

Opened from the Settings button in the popover or header, or with ⌘,. It is a single instance.

### 3.15 Global states (ADDED)

| State | Where | Spec |
|---|---|---|
| **Unavailable value** | Any value | "—" (U+2014) in `textTertiary`, same font as the value it replaces. `.help(reason)` tooltip, e.g. "Sensor not available on this Mac", "Requires root", "Not reported by IOReport". Unit suffixes are dropped (show "—", not "— W") |
| **Idle / zero rate in tables** | Per-app rate cells | "—" in `textTertiary`, no tooltip (as the design does for Xcode's network) |
| **Collecting** | Any chart with fewer than 2 samples in range | Chart frame keeps its size; draw nothing, and center "Collecting…" in `caption` `textTertiary`. The stat values show the first sample as soon as one exists |
| **Partial history** | Range extends before the first stored sample | The region before the first sample is filled with `fillTrack`, with a `micro` "No data yet" in `textTertiary` centered if 60 or more wide |
| **Paused** | Charts | Gap in series (§2.3). History band "Paused". Popover status: `statusPaused` dot, "Sampling paused". Header sub on Overview: "Sampling paused". Pause buttons show `play` |
| **Empty table** | Any table | Rows area 80 tall, centered `body12` `textSecondary`: "No processes match “{query}”" (search), "No network activity", "No GPU clients", "No disk activity", "No apps preventing sleep" |
| **Empty card** | Fans / Battery / Media engines | Card keeps its layout height; centered `body12` `textSecondary` message ("This Mac has no fans", "No battery") |
| **First launch** | Popover and Overview during the first 2 s | Values "—", sparklines "Collecting…" |
| **Store error** | History | Centered in the timeline card: `body12` `textSecondary` "History is unavailable." plus the error in `caption` `textTertiary` |

### 3.16 Overlay (ADDED 2026-09-25)

Spec: `docs/superpowers/specs/2026-09-25-overlay-design.md`.

- **Content** (`OverlayView`, MonitorScreens): one row of three columns, CPU · GPU · MEM, 16 apart, padding 8 × 6.
  - Column: label (`captionMedium`, category colour `cpu`/`gpu`/`mem`) and value (`body13Value`) on one baseline; below it the 60-s stats row "↓{min} ↑{max} ø{avg}" in `micro` `textSecondary`.
  - CPU/GPU values are `TTFormat.percent`; their stats are integer percent without "%". MEM value is `memory(.headline)`; its stats use `memoryNumber` (no unit).
  - MEM value tint follows memory pressure: `statusElevated` (warning), `statusCritical` (critical), else `textPrimary`.
  - Unavailable: value "—" in `textTertiary`, stats "— — —". No value yet (first tick): value "—" in `textTertiary`; no samples in the window: stats "—".
  - Each column sits over a hidden worst-case template ("100%", "999.9 GB"; "↓100 ↑100 ø100", "↓999.9 ↑999.9 ø999.9"), so the overlay keeps one size (~333 × 44 pt) whatever the values.
  - Background: rounded rect radius 8, `bgElevated` at the opacity setting, 1-pt `separator` border. Always dark; no animation. Sampling paused → whole overlay at 50 %.
- **Window** (App, `OverlayPanelController`): borderless non-activating `NSPanel`, `.statusBar` level, click-through, no shadow, on every Space and over full-screen apps, never key. Placed 8 pt inside the visible frame of the display under the mouse, in the chosen corner (default top-right); it follows the mouse to another display on the next tick.
- **Toggle**: global hotkey (default ⌥Z, Carbon, no Accessibility permission), the popover footer overlay button (tinted `accent` when on; tooltip "Overlay (⌥Z)"), or Settings. The state persists across launches.
- **Settings › Overlay** section (after General): "Show overlay" switch; "Shortcut" recorder (Esc cancels; needs ⌘, ⌥ or ⌃; ⌘-only standard shortcuts rejected; "Shortcut unavailable — in use by another app" in `statusElevated` when registration failed; note "⌥Z blocks typing Ω." for the default); "Corner" ↖ ↗ ↙ ↘; "Opacity" 55/70/85/100 % (default 85).

---

## 4. Status icon

### 4.1 Canvas and geometry

- Status item: `NSStatusItem.squareLength`. The image is 18×18 pt, drawn at 1× and 2×.
- The design draws the glyph in an 18×18 viewBox rendered at **16 pt** in the menu bar (and at 20 pt in the popover header, 72 pt on the reference card; those two scale the viewBox directly with no 8/9 factor, see §4.3). So: in the 18-pt menu bar canvas, draw the viewBox geometry scaled by **s = 8/9**, around the canvas center (9, 9).

Reference geometry, in viewBox units (y-down, origin top-left, angles θ measured **clockwise from 12 o'clock**):

| Element | Geometry |
|---|---|
| Center | (9, 9) |
| Arc radius | 6.4 |
| Arc stroke | 2.2, round caps, no fill |
| Arcs | 5 arcs of 58°, gaps of 14°. Arc *i* (i = 0…4) spans θ = 7° + 72°·i → 65° + 72°·i |
| Arc 0 CPU | 7° → 65°: (9.78, 2.65) → (14.80, 6.30) |
| Arc 1 GPU | 79° → 137°: (15.28, 7.78) → (13.36, 13.68) |
| Arc 2 Memory | 151° → 209°: (12.10, 14.60) → (5.90, 14.60) |
| Arc 3 Network | 223° → 281°: (4.64, 13.68) → (2.72, 7.78) |
| Arc 4 Thermals | 295° → 353°: (3.20, 6.30) → (8.22, 2.65) |
| Center dot | filled circle at (9, 9); r = 1.4 calm, 1.6 elevated, 2.1 critical |

Point formula (y-down): `x = 9 + r·sin θ`, `y = 9 − r·cos θ`.

Final values in the 18-pt canvas (× 8/9): arc radius **5.689**, stroke **1.956**, dot r **1.244 / 1.422 / 1.867**. The center stays (9, 9) and the angles are unchanged. The glyph's outer extent is r + stroke/2 = 6.667, so it spans 2.33…15.67 pt and leaves about 2.3 pt of clear margin.

Note: with round caps, adjacent arc ends almost touch (the 14° gap chord is 1.39 pt against a cap overhang of 0.98 pt on each side). That is the design and must not be "fixed". The caps of neighboring arcs overlap by about 0.57 pt along the stroke centerline, so paint order and compositing matter (§4.2).

### 4.2 Drawing instructions

**SwiftUI `Canvas` / `Path`** (y-down). SwiftUI's `clockwise` flag is inverted in flipped space, so `clockwise: false` draws visually clockwise:

```swift
let c = CGPoint(x: 9, y: 9), s: CGFloat = 8.0/9.0
let r = 6.4 * s, lw = 2.2 * s
for i in 0..<5 {
    let start = 7.0 + 72.0 * Double(i), end = 65.0 + 72.0 * Double(i)
    var p = Path()
    p.addArc(center: c, radius: r,
             startAngle: .degrees(start - 90), endAngle: .degrees(end - 90),
             clockwise: false)
    ctx.stroke(p, with: .color(color(for: i)), style: StrokeStyle(lineWidth: lw, lineCap: .round))
}
ctx.fill(Path(ellipseIn: CGRect(x: 9 - dotR*s, y: 9 - dotR*s, width: 2*dotR*s, height: 2*dotR*s)), with: .color(dotColor))
```

**AppKit `NSBezierPath`** (non-flipped image, y-up). Angle φ is measured counter-clockwise from +x, with φ = 90° − θ:

```swift
let path = NSBezierPath()
path.appendArc(withCenter: NSPoint(x: 9, y: 9), radius: r,
               startAngle: 90 - start, endAngle: 90 - end, clockwise: true)   // e.g. 83° → 25° for arc 0
path.lineWidth = lw; path.lineCapStyle = .round; color.setStroke(); path.stroke()
```

Check arc 0 in the 18-pt canvas: the start point is (9 + 5.689·sin 7°, 9 − 5.689·cos 7°) = (9.693, 3.353) in y-down coordinates.

**Paint order and compositing** (required, because the round caps overlap):
1. **Group arcs by color.** All non-stressed arcs go into **one** `Path` (or `NSBezierPath`) with one subpath per arc, and are stroked **once**. Each stressed color gets its own single-path stroke the same way. A single stroke of one path never double-covers its own overlap, so no alpha buildup occurs.
2. **Order**: stroke the non-stressed (label-color / template) path first. Then stroke the stressed path(s), elevated before critical. Then fill the center dot last. A stressed arc's caps therefore sit on top of its neighbors' caps.
3. **Transparency layers**: wrap the whole glyph in one transparency layer. Its alpha carries **only** the paused 0.5. The overlap between differently colored neighbors then does not composite twice against the menu bar.
   - The critical **pulse** (§4.3, 1 → 0.45 → 1) dims only the stressed-color sub-path. Draw that path in its **own** nested transparency layer and apply the pulse alpha to that layer. The non-stressed path and the dot stay at full alpha.
   - SwiftUI: `ctx.drawLayer { … }` with `ctx.opacity` set on the outer context.
   - AppKit: `CGContext.beginTransparencyLayer(auxiliaryInfo:)` … `endTransparencyLayer()` with `setAlpha` before it.
4. The template (calm) image follows the same rule: one path for all 5 arcs plus the dot, drawn opaque black.

### 4.3 States

| State | Arcs | Center dot | Image type | Behavior |
|---|---|---|---|---|
| **Calm** | all 5 in black (template) | r 1.4, black | `isTemplate = true` | Follows the menu bar tint (light or dark, highlighted) |
| **Elevated** | stressed arc(s) `#FFB340`; the other arcs in the menu bar label color | r 1.6, `#FFB340` | `isTemplate = false` | Caption: "The stressed category's arc and the center turn amber." |
| **Critical** | stressed arc(s) `#FF453A`; the other arcs in the label color | r 2.1, `#FF453A` | `isTemplate = false` | Pulses once on entering critical, then stays red until the stress clears |

- **Label color for non-template states**: build the image with `NSImage(size:flipped:drawingHandler:)`. The handler runs at draw time under the status button's effective appearance, so resolve `NSColor.labelColor` inside it. That yields white on a dark menu bar and black (≈0.85 alpha) on a light one. Do not cache a bitmap.
- **Which arc is stressed**: Thermal alerts use arc 4. Memory alerts use arc 2. Runaway app uses arc 0. Several alerts tint several arcs, each in its own severity color. The dot takes the highest severity.
- **Pulse**: 600 ms, ease-in-out. The dot radius goes 2.1 → 2.9 → 2.1 (viewBox units) and the stressed arc's opacity goes 1 → 0.45 → 1. Render 18 frames at 30 fps by swapping `button.image`, then leave the static critical image. It runs once per transition into critical, and never while Reduce Motion is on.
- **Paused** (ADDED): the calm template drawn at 0.5 alpha. Alerts are suppressed while paused.
- **Accessibility**: `button.setAccessibilityLabel("Telltale, \(statusLine)")`. Tooltip: the status line.
- **Popover header glyph**: `MenuBar.dc.html` draws it as `svg width=20 viewBox="0 0 18 18"`. It is the **viewBox geometry scaled by 20/18 into a 20×20 frame**, with **no** 8/9 factor: center (10, 10), arc r 7.111, stroke 2.444, dot r 1.556 / 1.778 / 2.333. It uses the same state colors, paint order and compositing. The calm arcs use `textPrimary` `#F2F2F4`.

---

## 5. Number formatting rules

This is one rule set for every screen; the design's inconsistencies are resolved here (§6 lists them). Implement it as `enum TTFormat` with pure functions and unit tests. The locale is `Locale.current` for grouping separators and dates. The design's samples are en-US (`3,104`).

### 5.1 General
- Unavailable: "—" (§3.15). NaN or negative-where-impossible counts as unavailable.
- Units are separated by a regular space ("18.6 W", "12 cores"), except `%` and `°C`/`°F`, which attach directly ("34%", "62°C").
- Rounding is half-to-even through `FormatStyle`. Never show "-0".
- The minus sign is U+2212 "−", for example "−18.9 W" and "−52 dBm".
- Do not trim trailing zeros, except in capacity totals (§5.3).

### 5.2 Percent
| Context | Rule | Example |
|---|---|---|
| System headline (popover, tiles, sidebar, stat "Total", per-core, pressure, battery, History lanes) | integer | `34%` |
| Breakdown / per-app (stat User/System/Idle, tables, inspector, Top consumer) | 1 decimal; Top consumer detail line uses integer | `22.1%`, `212.4%`; "212% CPU" |
| Per-app CPU | % of one core (can exceed 100) | `812%` |
| Packet loss | 1 decimal | `0.0%` |
| Table cells whose header contains "%" ("% CPU", "% GPU") | omit the sign | `212.4` |
| Table cells whose header lacks "%" ("CPU", "GPU") | include the sign | `212.4%` |
| Health / wear | integer + word | `94% maximum capacity`, `2% used` |

### 5.3 Bytes (memory and storage)
- **Memory** uses binary units (÷1024) but labels them "GB"/"MB", matching Activity Monitor.
- **Storage and network totals** use decimal units (÷1000), matching Finder.

| Magnitude | Headline (popover, tiles, stat strips, sidebar, composition) | Tables, inspector, detail |
|---|---|---|
| < 1 MB | `{int} KB` | `{int} KB` |
| < 1 GB | `{int} MB` | `{int} MB` (CHANGED: "0.48 GB" becomes "492 MB") |
| < 1 TB | 1 decimal GB: `15.1 GB` | 2 decimals GB: `3.82 GB` |
| ≥ 1 TB | 2 decimals TB: `1.24 TB` | 2 decimals TB |

Exceptions:
- **Swap** always uses 2 decimals: `1.20 GB`, `of 2.00 GB`.
- **Storage capacities** under 1 TB are integer GB (`382 GB`, `612 of 994 GB`). A capacity total of ≥ 1 TB trims trailing zeros (`of 2 TB`, `1 TB`).
- **RAM total** is integer (`24 GB`), except the composition header, which is 1 decimal (`24.0 GB unified memory`).
- **Lifetime SSD totals** use 1 decimal TB (`48.2 TB`).

### 5.4 Rates (network, disk)
- Bytes/s, decimal units.

| Magnitude | Format | Example |
|---|---|---|
| 0 | headline `0 KB/s`; table `—` | |
| (0, 1 KB/s) | `<1 KB/s` | |
| < 1 MB/s | integer KB/s | `840 KB/s`, `12 KB/s` |
| 1–99.9 MB/s | 1 decimal | `12.4 MB/s`, `38.0 MB/s` |
| 100–999 MB/s | integer | `142 MB/s` |
| ≥ 1 GB/s | 2 decimals GB/s | `1.05 GB/s` |

- Compact pair (popover Disk): `R 142 · W 38.0 MB/s`. The unit appears once, after the last value.
- The **Bits/s** setting applies to network values only: multiply by 8 and use `Kbps`/`Mbps`/`Gbps` with the same magnitude rules. Link rates are always Mbps, integer, grouped (`1,201 Mbps`).
- Direction prefixes: `↓ ` / `↑ `.
- IOPS: < 1000 integer; ≥ 1000 as `{1 decimal}k` (`3.4k IOPS`).
- Pages/s and swaps/s: integer with " / s" (`0 / s`); in the Page-ins stat as `412 · 0` with the sub "per second".

### 5.5 Temperature
- Integer, `°C` (or `°F` per Settings; F = C·9/5 + 32, rounded after conversion).
- Compact contexts (sidebar trailing value, y-axis labels) show `°` only: `62°`, `105°`.
- Temperature chart domains are defined in °C and relabeled when °F is selected.

### 5.6 Power and energy
| Context | Rule | Example |
|---|---|---|
| System (package, components, battery drain) | 1 decimal W | `18.6 W`, `0.2 W`, `−18.9 W` |
| Per-app average power (tables, inspector, treemap, popover flyout) | ≥ 10 W: 1 decimal; 0.01–9.99 W: 2 decimals; > 0 and < 0.01 W: `<0.01 W`; 0 → `—`. Source: `ri_energy_nj` deltas (rusage v6) plus the coalition residual for root processes; estimated values carry an "Estimated" tooltip | `12.4 W`, `7.15 W`, `4.82 W`, `0.35 W`, `<0.01 W` |
| Battery capacity | 1 decimal Wh | `68.1 of 72.4 Wh` |
| Adapter | integer W | `96 W` |

### 5.7 Frequency, rpm, misc
- CPU cluster frequency: GHz with 2 decimals (`4.12 GHz`). In the popover sub-line: 1 decimal (`4.1 GHz`).
- GPU frequency: integer MHz, grouped (`1,180 MHz`).
- Fans: integer, grouped, lowercase unit (`2,140 rpm`). Maximum label: `max 5,700`.
- Load average: 2 decimals, joined by ` · `.
- Counts: integer, grouped (`3,104`, `612`).
- Latency: integer ms (`18 ms`); below 1 ms shows `<1 ms`.
- RSSI: integer dBm with U+2212 (`−52 dBm`).
- Compression ratio: 1 decimal, `{r} : 1`.
- Wi-Fi channel: integer.

### 5.8 Durations and times
| Context | Rule | Example |
|---|---|---|
| Time remaining, uptime, "for {duration}" | two largest non-zero units from d/h/m, space-separated, no leading zeros; under 1 min shows `<1 m` | `5 h 40 m`, `4 d 7 h`, `12 m` |
| Battery phrase | popover and Overview: `{pct}% · {dur} left`; Battery card: `On battery · about {dur} left` / `Charging · full in {dur}` / `Charged` | |
| CPU time / GPU time (cumulative) | `m:ss` under 1 h; `h:mm:ss` from 1 h (hours unbounded) | `58:12`, `2:41:07`, `0:52` |
| Clock times (History cursor, chips) | 24-hour `HH:mm` | `14:35` |
| Popover and menu-bar dates | locale default (`.dateTime.weekday().day().month().hour().minute()`) | |
| History header | `EEEE, d MMMM` (locale-ordered) | `Thursday, 24 September` |
| Power-on hours | integer, grouped | `3,412` |

### 5.9 Names and truncation
- App and process names: single line, tail truncation with `…`, in the width their column allows. There is no fixed character limit.
- Display names come from, in order: localized app name (`NSRunningApplication.localizedName`), `CFBundleName`, then executable name.
- Executable paths (inspector): **middle** truncation.
- Remote hosts: middle truncation (keeps the TLD visible).
- Treemap labels: tail truncation; hidden below the size thresholds in §2.28.
- Sensor names: tail truncation; the detail text truncates first (use a lower layout priority).
- Popover row sub-lines: tail truncation. The value column (74) never truncates. If a value exceeds 74 pt, it scales down to 0.85 minimum.

### 5.10 Chart domains and display buckets
| Series | y-domain |
|---|---|
| CPU %, GPU %, Memory pressure % | 0–100 |
| Memory used | 0–physical RAM |
| Swap | 0–allocated swap |
| Temperature (popover/Overview) | 0–100 °C |
| Temperature (Thermals chart) | 40–105 °C (labels 105/89/72/56/40) |
| Temperature (History lane) | 35–100 °C |
| Network / disk rates, power, ANE, per-app | auto: the smallest "nice" ceiling ≥ the window max, from {1, 2, 4, 5, 10, 20, 40, 50, 100, 200, 400, 500, 1000…} in the display unit (minimum 1 MB/s, 1 W). The legend shows it as "scale {N} MB/s". The ceiling only grows during a Live session; it re-evaluates on range change |
| GPU frequency overlay | 0–max GPU MHz |

| Range | Window | Display bucket (points) | Store source |
|---|---|---|---|
| Live | 60 s | 1 s (60) | in-memory ring |
| 1H | 1 h | 15 s (240) | full-res |
| 24H | 24 h | 5 min (288) | full-res |
| 7D | 7 d | 30 min (336) | 1-min rollup |
| 30D | 30 d | 2 h (360) | 15-min rollup |

Bucket aggregate: mean for rates and %, max for temperatures (the stored peak).

---

## 6. Ambiguities resolved

1. **Popover width.** The artboard is 440 wide, but that includes the fake menu bar and desktop. The popover panel itself is **360** wide (the HTML `width: 360px`). Built at 360.
2. **Popover position.** The mock right-aligns the popover to the screen edge (12 in). Built horizontally centered on the status item, 8 below the menu bar, and clamped to the screen.
3. **Popover shape.** The design has no arrow, so it is a borderless `NSPanel`, not an `NSPopover`.
4. **Menu bar glyph size.** The viewBox is 18, rendered at 16 in the design. Built as an 18-pt canvas with the glyph scaled 8/9, so it matches the mock's visual size.
5. **Range sets.** The design shows `Live 1H 24H 7D` on category pages and `1H 24H 7D 30D` on History. Per the SPEC ruling, every page gets `Live 1H 24H 7D 30D`. On History, Live pins the cursor to now and follows it (§3.13), and History still defaults to 24H.
6. **History subtitle.** "5-minute resolution for 24 h" describes display buckets, not storage (the store keeps full resolution for 24 h). The copy is kept and made range-dependent.
7. **Row selection fill.** The design uses `#0A84FF` at 0.22 (CPU and Power tables) and at 0.28 (Processes). Unified to 0.28.
8. **"Residency" vs "Active residency"** on the P and E cards. Unified to "Active residency".
9. **Energy copy vs watts.** The ruling requires watts. Headers "Energy impact"/"Energy" and the sort label "Energy" are kept as design copy; values become W (§5.6). The 12 h average is also in W.
10. **App grouping vs the design's sample rows.** The design's rows (Xcode, Final Cut Pro, Safari, WindowServer, com.docker.backend) do **not** follow any one grouping rule. The ruling (§3.12) is:
    - Bundled apps group by responsible PID, so `com.docker.backend` rolls up under **Docker Desktop**.
    - A daemon with no bundle is its own group, named by its process, so **WindowServer stays a row**.
    - Unattributable root processes appear as coalition rows (provenance `.coalition`, named by the coalition leader's `p_comm`).
    - Anything else is summed into "System".
    - Overview "Top processes", Power "Energy impact", GPU clients, Memory and Network tables all use app groups. The "Top processes" title copy is kept.
11. **Per-app memory precision.** The design mixes "0.48 GB" and "894 MB". Rule: under 1 GB always shows MB.
12. **Rate precision.** The design mixes integer ("38 MB/s" stat) and 1 decimal ("1.2 MB/s" table). Rule: 1 decimal below 100 MB/s, integer at 100 and above, everywhere. The "0.1 MB/s" table value becomes "100 KB/s" via the KB rule.
13. **Percent sign in tables.** It depends on whether the header contains "%". This reproduces both the Overview and the Processes/CPU tables unchanged.
14. **Letter tiles.** These are placeholders in the mock. The real app icon is used when available; the letter tile is the fallback. The letter is always uppercase (the design has both "c" and "C").
15. **Path truncation.** CSS tail truncation becomes middle truncation for paths and hosts, so the bundle and host stay visible.
16. **Memory pressure legend thresholds.** "≥ 60%" and "≥ 80%" are not the OS's definition. The level colors follow `kern.memorystatus_vm_pressure_level`, and the legend copy drops the thresholds.
17. **Thermal "Fair" color.** The scale segment uses `#C8D64A`, but the alert, icon and popover use amber. Both are kept: the level scale uses the per-level colors, and alerting states map Fair and Serious to elevated (amber) and Critical to red.
18. **Thermal scale lighting.** Only the current level is lit, not a cumulative fill.
19. **ANE card.** The ruling removes %. The headline becomes W, and the right-hand text becomes "idle"/"active"; the sparkline plots W.
20. **Media engines.** Kept only with IOReport data, and the codec label is dropped. If there is no data, the card is removed and ANE fills the column.
21. **Memory table columns.** Compressed, Private and Ports are removed unconditionally (architecture review). The table is Process | Memory | actions.
22. **Top consumer "· exporting".** Removed, because there is no activity-description source.
23. **"Sample" button.** It is not in the spec and not dropped by the rulings. Kept as design (`/usr/bin/sample`, owned processes only).
24. **"Undo demo" link.** Prototype-only, so removed. The toast remains.
25. **Where the treemap lives.** History has no spare vertical space, so the "At" card is restyled as a 220-pt info column plus the treemap, which keeps all of the design's At-card content.
26. **Where App detail lives.** It is the Processes inspector expanding in place (ruling wording), not a new page.
27. **Quit Telltale placement.** An icon button in the popover footer, with ⌘Q, to keep the footer's two-button look.
28. **Popover reorder/hide (SPEC) vs fixed design order.** The design order is the default. Reorder and hide live in Settings → Popover.
29. **Chart y-scales.** The design's fixed demo scales (40 MB/s, 4 MB/s, 600 MB/s, 30 W) become auto "nice" ceilings, and the legend still states the scale.
30. **Idle vs unavailable "—".** The design uses "—" for idle table cells. Both meanings keep "—"; only the unavailable one carries a tooltip.
31. **Wi-Fi header.** With the SSID removed, the header becomes "Wi-Fi 6E · 5 GHz · 1,201 Mbps link".
32. **Hover, pressed and disabled states.** The design shows only rest states. The added states use existing opacity steps (0.05 hover, 0.14 button hover, 0.40 disabled).
