# Network Monitor page — design

Date: 2026-09-24 · Status: approved design rev 2 (post-review), pre-plan

## 1. Goal

Add a **Network Monitor** page to the dashboard: a Little-Snitch-style observer that answers three questions — *who is using my bandwidth right now?*, *what did this app talk to?*, *is anything phoning home?* — by showing every app's connections (app → remote host → socket), bandwidth over time, listening sockets, a persisted per-app/per-host history, and eventually a world map. All data comes from the existing unprivileged NetworkStatistics (NStat) source plus libproc and Security.framework.

This is **sub-project A** of two. Sub-project B (firewall: NetworkExtension content filter, allow/deny rules, prompts) gets its own interview, spec and plan after A ships; A leaves room for B's verdicts (§12).

A ships in four phases (§10): **A1 live**, **A2 history**, **A3 alerts**, **A4 map**.

Non-goals (all of A): blocking/filtering, real queried DNS names or TLS SNI (need B), ASN/org DB, interface "Via" column, DNS-resolver header, metered-network banner, timeline spike attribution, parent/launchd attribution for CLI tools, LAN device list, data-usage report/CSV export, saved filters, mute/ignore list, tracker lists, zoomable street map, quit/force-quit from this page.

## 2. Decisions

### From interview

| Topic | Decision |
|---|---|
| Scope | Monitor + firewall overall; A (monitor) first, B (firewall) later with its own spec |
| Signing | Free/personal team. Irrelevant for A; for B it means local-only with SIP partly off (§13) |
| Placement | New sidebar page `Network Monitor`, Activity section. Network page keeps interfaces/throughput/Wi-Fi; its per-app table becomes a top-5 card + link |
| Phasing | A1 live · A2 history + New + background tagging · A3 alerts + popover · A4 city geo + map + updater |
| Hierarchy | App → host → connection tree |
| Closed connections | Live + recent: closed flows stay dimmed 5 min (capped, §4) |
| History | Persisted aggregates per (app, host, remote port, proto) per bucket; no per-socket log |
| Retention | Host level: `net_1m` 26 h, `net_15m` 7 d. Beyond 7 d: app level only, from existing `app_15m` (30 d) |
| Background capture | Always on; host-level data recorded while the page is closed |
| Timeline | Live last 1 h; A2 adds 24h/7d/30d. History ranges show app/host rows only |
| Host naming | Reverse DNS (forward-confirmed) + bundled known-provider IP ranges; real domains/SNI deferred to B |
| Host grouping key | Fallback chain (§6), eTLD+1 from ICANN section of the Public Suffix List |
| GeoIP | Offline. A1: bundled DB-IP Country Lite (flags, country search). A4: DB-IP City Lite downloaded in-app monthly |
| Geo format | DB-IP `.mmdb` read by an in-house mmap MMDB reader; no custom converter |
| Map | A4, last. Bundled Natural Earth 110m vector world drawn in SwiftUI `Canvas`; no MapKit |
| Visuals | Scrubbable traffic timeline, inspector panel, top-talkers row, world map (A4) |
| Extra data | Average RTT (inspector only), code-signing identity per app |
| Extra views | Listening sockets, port/service labels (IANA) |
| New | `New` chip + `New since yesterday` preset from first-seen (app, host) pairs (A2) |
| Background tagging | Bytes tagged background (app not frontmost) and away (screen locked / display asleep); `Background` chip (A2) |
| Alerts (A3) | First network access, unsigned binary connects, new non-loopback listener. OS notifications off by default per alert; event log + badge always; learning period |
| List | App row shows host count (not connection count); RTT in inspector only |
| Chips | `Active · New · Background · Unsigned · Internet only` (Internet only default on); proto/family/port/country/state via search tokens |
| Top talkers | One row: top apps now \| top hosts now. No countries card |
| Actions | Copy; reveal in Finder; open in Processes; ipinfo lookup + "More lookups" (whois, Shodan). No quit on this page |
| Clear / exclude | Clear network history (by range) in Settings › Privacy; "Don't record" per app in inspector + Settings |
| Integration | Processes `ConnectionsPanel` link + enrichment (A1); Network page top-5 card (A1); popover mini-card (A3) |
| Layout | Timeline strip on top, `List \| Listening \| Map` switcher, collapsible inspector on the right |

### Defaults chosen without interview

- Closed-flow dim window 5 min; at most 500 closed rows per app, rest collapse into a `+N closed` row on the host.
- "My location" (map arc origin, A4) is a manual city setting, default none: arcs hidden, dots shown. No public-IP discovery.
- Known ranges, PSL, IANA ports, Country Lite DB: bundled, refreshed by `scripts/update-ranges.sh`. City DB (A4) is the only in-app download.
- Excluded apps are recorded nowhere (no `net_*` rows, no `net_seen`) and raise no alerts.
- Loopback bytes excluded from all totals (both ends are NStat sources, so they would count twice). Loopback flows still listable with `Internet only` off.
- Reverse DNS has a settings toggle (default on).
- History DB, `-wal`, `-shm` mode `0600`, data directory `0700`, applied at open to existing files too.

## 3. Architecture

**Approach:** extend the existing pipeline. The single long-lived NStat manager in `NStatSensor` stays the only source (creation 0.3–1.3 s, query ~25 ms — never duplicated). Rejected: a second NStat pipeline (double cost, two truths for bytes); `nettop`/`lsof` (CPU, fragile, no RTT).

### Layering

```
MonitorSensors ──► RawTick.networkFlows (live + drained closedFlows)
        │
MonitorEngine (engine actor) ── uses MonitorNet pure units:
        FlowTracker → NetAggregator → NetWindowIndex, NetAlerts (A3)
        reads HostInfoCache snapshot (sync, lock-box)
        emits RecordBatch.net rows ──► MonitorStore
        emits SystemFrame.network: NetSnapshot ──► MonitorLive
MonitorRuntime ── owns MonitorNet I/O units on their own serial queues:
        NetEnricher (ReverseDNS, KnownRanges, MMDB, SigningInfo), GeoUpdater (A4)
MonitorLive ── NetworkMonitorModel: builds flat visible rows off-main via MonitorNet.NetRowBuilder
MonitorScreens ── Pages/NetworkMonitor/* (never imports MonitorNet or MonitorStore)
App ── NotificationCommands closure struct (A3)
```

- **New SPM target `MonitorNet`** (depends on `MonitorModel` only). New edges: MonitorEngine → MonitorNet, MonitorRuntime → MonitorNet, MonitorLive → MonitorNet, telltale-probe → MonitorNet. Added to the "UI never imports" rule alongside MonitorStore.
- **Pure units** (no I/O, run wherever called): `IPAddress` utilities, `ScopeClassifier`, `PublicSuffix`, `KnownRanges` (lookup), `PortNames`, `MMDBReader`, `HostResolver` (naming chain logic), `FlowTracker`, `NetAggregator`, `NetWindowIndex`, `NetRowBuilder`, `NetAlerts`, `ExecKey`.
- **I/O units** (instantiated by MonitorRuntime, box pattern on a private serial `DispatchQueue` like `ReverseDNS`; blocking calls never run on the cooperative pool): `ReverseDNS` (moved from MonitorSensors with its tests), `SigningInfo`, `NetEnricher`, `GeoUpdater` (A4, writes under the runtime `dataDirectory`).
- **Enrichment handshake:** once per tick the engine sends `NetEnricher` the deduped set of IPs and executables it has not seen. `NetEnricher` resolves asynchronously and publishes into `HostInfoCache` (lock-box, `IPAddress → HostInfo`, `ExecKey → SigningIdentity`). The engine reads it synchronously, in O(1), and never awaits. The queue is bounded, drop-and-retry like `ReverseDNSJobs`, and rDNS goes through a 20/s token bucket.
- **Frame:** new optional `SystemFrame.network: NetSnapshot` carrying per-app/per-host aggregates, live flows, closed-flow tail, timeline tail, and listening sockets. It is built when the `.networkMonitor` demand is on, or for the popover card (A3). `FrameAssembler` does **not** build `frame.connections` for every flow; `connections()` stays inspected-app only for `ConnectionsPanel`.
- **Demand:** new `SamplingDemand.networkMonitor` while the page is visible (1 s cadence; builds `NetSnapshot`). Endpoint decoding (`setWantEndpoints`) is forced on always, because background aggregation needs it.
- **UI boundary:** `NetworkMonitorModel` in `MonitorLive` holds the snapshot, filters, window, expansion state and selection. It builds a flat `[NetRow]` of *visible* rows only (collapsed children are not built), off-main, with stable ids (AppKey / hostKey / flowID). `NetworkMonitorActions` is a closure struct for copy, reveal, lookups, open in Processes and exclude app. `NetHistoryProvider` (A2) is a protocol in MonitorModel (queries plus clear/exclude), implemented in MonitorStore, with Empty and Mock implementations.
- **Settings:** `network.*` keys in `SettingsStore`: `rdnsEnabled`, `excludedApps: [AppKey]`, `alerts.{firstAccess,unsigned,listener}` (A3), `learning.{recordedSeconds,distinctDays}` (A3), `geo.updatesEnabled`, `geo.lastUpdated`, `myLocation` (A4). Exclusions reach the engine through a runtime command, like `.visibility`.
- **Cost budget:** background CPU no more than **+0.1 % of one core** over today's 0.5–0.65 % (ARCHITECTURE.md:1343), measured by `telltale-probe`. Advisory, not a gate.

### Navigation / ICR

- ICR **017** (storage spec is 016; land after it). It touches `Navigation.swift`, `DashboardRoot.swift`, `Sidebar.swift`, `Sampling.swift`, `ScreenCatalog.swift`, `PageHeader.swift`, `TTIcon.swift`, `TTSidebarItem.swift`, telltale-probe `Options.swift` and `LaunchOptions.swift`. A3 adds `HistoryEvent.Kind.network`, which touches `HistoryPresentation.swift` and every other exhaustive switch on `Kind`.
- It also covers the locked-API changes: `FlowCounter` optional fields, `NetworkFlowsReading.closedFlows`, `IPAddress`, `RecordBatch.net`, `SystemFrame.network`, and the schema bump (§5).
- **SPEC ruling needed for these conflicts:**
  - connections live-only (SPEC.md:105) versus persisted aggregates (A2);
  - "No Notification Center" (SPEC.md:14, :109) versus A3;
  - "no outside services" (SPEC.md:27) versus the A4 geo download;
  - "no endpoints/rDNS in background" (ARCHITECTURE.md:1347) versus always-on capture;
  - the background budget (ARCHITECTURE.md:1325, :1343).

## 4. Page layout

### Header
Title; range picker (`Live 1h` in A1; `24h | 7d | 30d` added in A2); pause-live toggle.

### Timeline strip
- Stacked in/out area chart of NStat bytes, **Unattributed included**. A tooltip notes it runs 4–10 % below the Network page interface counters, because NStat sees TCP/UDP only.
- **Resolution:** 1 s while the page is visible, 10 s otherwise. The part recorded before the page opened is drawn at 10 s.
- **Gaps:** paused, asleep and no-data spans are drawn as gaps, not as 0 B/s. After a gap the timeline re-baselines rather than dumping the whole gap into one point.
- **A2 history ranges:** read `net_1m` (24h) and `net_15m` (7d), with the unflushed pending minutes merged in. 30d reads `app_15m` at app level. On launch the 1 h ring backfills from `net_1m`.
- **Interaction:** drag selects a window and everything below filters to it; double-click clears. Hover shows rate and time. A3 draws alert ticks on the axis.

### Toolbar
- **View switcher:** `List | Listening | Map`. `Map` appears in A4.
- **Search:** free text matches app, host, IP, CIDR and provider label. Tokens: `proto:tcp|udp`, `v4`, `v6`, `port:443`, `country:DE`, `state:listen|closed|established`, `app:`, `host:`.
- **Chips:** `Active` (hide closed) · `New` (A2) · `Background` (A2) · `Unsigned` · `Internet only` (on by default: hides loopback and LAN).
- **Sort:** rate now (live default), window total (history default), hosts, last active.

### Top talkers
- One row, two halves: `Top apps now` | `Top hosts now`, top 5 each by bytes in the current window.
- Uses partial top-k selection, not a full sort. Clicking an entry filters the list.

### List (tree)
- **App row:** icon, name, signing badge (Apple / team name / ⚠ unsigned / ad-hoc / locally built), ↓ now, ↑ now, window total, hosts, last active. Sparkline shows on hover only, drawn in one `Canvas` path from a 60-point ring.
- **Host row:** best name (`(unverified)` suffix when rDNS failed forward-confirm), provider label, country flag, ↓/↑, window total. IPs show on hover.
- **Connection row:** `local:port → remote:port`, service name, proto, state, interface, bytes, age, `via <helper>` when the socket owner is not the app.
  - Closed rows are dimmed ("closed 2m ago").
  - In a window, a connection row shows bytes inside the window if it has samples there, otherwise lifetime bytes with a marker.
- **Special nodes:**
  - `(no remote)` host node for unconnected UDP.
  - `Unattributed` app row: "Short-lived flows the kernel couldn't tie to an app".
  - `Kernel` row, separate from Unattributed, for flows reported as pid 0.
  - `iCloud Private Relay` host label: destination hidden, no geo.
  - VPN tunnel carrier flow: listed with a `Tunnel carrier` label and excluded from the timeline, top talkers and totals, because its bytes are already counted on `utun`.
- **Rendering:**
  - Uses the `ProcessListTable` pattern: `LazyVStack` + `Equatable` rows, pre-formatted strings, quantized values.
  - No `OutlineGroup`/`List` at 1 Hz.
  - Re-sorts at most every 3 s, or when a rank changes by more than one position, so rows don't jump.
- **History ranges:** app and host levels only. A note says per-connection detail is live-only. Beyond 7 days the list is app level only.

### Listening
- **Table columns:** process, proto, bind address, port, service, since.
- **Scope highlighting:** `*`, `0.0.0.0` and `::` binds (dual-stack treated as wildcard) get a warning tint. Loopback binds are plain.
- **Known Apple listeners** (ControlCenter AirPlay 5000/7000, rapportd, sharingd, …) get an `Apple service` badge instead of the tint.
- **Unconnected UDP on ephemeral ports (≥ 49152)** is hidden unless it is on a known service port. These are QUIC/WebRTC/DNS client sockets, not servers.
- **Limit (depends on spike, §10):** sockets owned by root or other users may be invisible. The footer states this when it applies.

### Map (A4)
- **Rendering:** Canvas world map (Natural Earth 110m). Geometry is converted at build time to Float32 polygons in a MonitorScreens resource and loaded when the Map tab first opens.
- **Layers:**
  - A static base layer, cached as a `CGImage` per size and color scheme.
  - A 1 Hz overlay of dots, one per geolocated IP location, area ∝ bytes in the window.
  - Anycast/provider ranges have no location: they are listed in a `Global` bucket, not drawn.
- **Arcs** from "My location" when set.
- **Interaction:** hover uses a bbox prefilter, then `path.contains`, and shows city (labelled "approx."), hosts and apps. Clicking a country filters the list.

### Inspector (collapsible; open by default at ≥ 1200 pt width)
- **App:**
  - Details: path, signing identity, notarized (computed lazily on open; `Notarized (stapled)` / `Not notarized` / `Unknown`), pid(s), top hosts.
  - A2 adds totals today and 7 d, first seen, and background/away share.
  - Actions: reveal in Finder, open in Processes, don't record (with "also delete this app's history").
- **Host:**
  - Details: rDNS name and whether it was verified, provider label, known IPs, country (A4: city, "approx."), remote ports, apps using it, average RTT. A2 adds first seen.
  - Actions: copy IP / host / `IP:port`; `Look up on ipinfo`; `More lookups` menu (whois, Shodan).
  - Lookups are never offered for LAN or loopback. URLs are built from the IP only, percent-encoded.
- **Connection:** every field, including RTT average and packets, plus a byte sparkline. Action: copy.
- **Empty:** "Select an app or host".

### States
- NStat unavailable: empty-state card with the reason; page disabled.
- Live, no internet traffic: "No internet traffic right now — N apps idle, M listening sockets".
- History before any data (A2): "Recording since 14:02 — history fills in as apps use the network".
- Geo DB missing or downloading (A4): the map shows a download button or progress; list unaffected.
- Global sampling paused: banner; timeline frozen.
- Empty filter result: "No matches" + clear filters.
- Excluded app: shown live with a "not recorded" badge; absent from history.
- Learning period (A3): no page banner; status shown only in alert settings (`Learning — Nh left`).

### Outside the page
- **Processes `ConnectionsPanel`** (A1): host names, country flags, "Open in Network Monitor".
- **Network page** (A1): per-app table replaced by a top-5 apps card + "Open Network Monitor →". Stays `AppSample`-based, with no MonitorNet dependency.
- **Popover mini-card** (A3): live connection count, top 3 talkers, alert dot; clicking opens the page.
- **Sidebar:** trailing value is the live connection count; A3 adds a badge dot for unseen alerts.
- **Settings › Privacy:** clear network history (last hour / day / all), excluded apps, rDNS toggle.
- **About:** DB-IP CC BY 4.0 attribution. Also shown next to geo data in the inspector and on the map.

## 5. Data model & store

### Live types (`MonitorModel/Network/`)
- `IPAddress`: 17 B value type (`UInt128` + family), with zone/scope id kept for link-local. Used everywhere; formatted only in row views. `inet_pton` round-trips are gone.
- **`FlowCounter` gains optional fields** (optional, so recorded fixtures still decode):
  - RTT avg/min/variance; verify the unit in the spike, and ignore 0 and UDP values;
  - rx/tx packets;
  - `startNs`: `startAbsoluteTime` converted from mach ticks via timebase;
  - local address + family;
  - remote as `IPAddress`.
- `NetworkFlowsReading.closedFlows: [FlowCounter]`: final counters and endpoints of sources removed since the last query, drained each reading.
- `NetFlow`: flowID, pid, epid, owner `AppKey` (responsible app of `epid ?? pid`), socket owner (for `via`), proto, local/remote endpoints, state, interface, rx/tx, packets, RTT, `openedAt`, `closedAt?`, flags (`relay`, `tunnelCarrier`, `kernel`, `unattributed`).
- `HostInfo`: scope (loopback / LAN / CGNAT / internet / multicast), provider label, rDNS name + verified flag, host key, country, city (A4).
- `SigningIdentity`: `.apple`, `.developerID(team:name:)`, `.adhoc`, `.linkerSigned`, `.unsigned`; `notarized: Bool?` (nil = not yet computed).
- `ListeningSocket`: pid, `AppKey`, proto, bind `IPAddress`, port, since.
- `NetSnapshot`: see §3. `NetRow`: a flat visible row with a stable id and pre-formatted strings.

### In-memory live window (`NetWindowIndex`)
- Per (app, hostKey): sparse 10 s buckets for the last hour, holding cumulative rx/tx/bg/away prefix sums. A window total is `cum[end] − cum[start]`, O(log n) per row; about 2 MB at 500 pairs.
- Total timeline ring: 3600 compact entries `(UInt32 tOffset, Float rx, Float tx)`. Reduced to min/max per pixel column before drawing.
- Recomputing on drag is throttled to ≤ 10 Hz, off-main.
- Session per-host totals: hosts idle for more than 1 h are evicted (the store covers them from A2).

### Accounting rules (`FlowTracker` / `NetAggregator`)
- **Identity** is the sensor's `flowID` (monotonic, never reused, survives `reset()`). It is not the `NStatSourceRef` pointer.
- **First sight:** delta = 0 unless `startNs` ≥ tracker start. This covers app launch, wake (`resetBaselines` also clears tracker and aggregator baselines) and sensor restart: no false spike.
- **Closed flows:** `NStatBox` keeps a closed-flow list capped at 4096; overflow folds into the per-process total. The list is drained into each reading. FlowTracker takes the final delta from it. `closedFlows` feeds host attribution only; `NStatFlowTable` stays the single place where per-process totals are folded, so there is no double count in `ProcessAssembler`.
- **Attribution:** owner = responsible app of `epid ?? pid`; the socket owner is kept for `via`. This moves `nsurlsessiond`/WebKit bytes to the requesting app. mDNSResponder delegation is checked in the spike.
- **Buckets:** each sample's delta goes to the minute of its sample wall-clock time (a boundary-straddling 10 s sample lands in the later minute; this is documented). Backward clock jumps are handled by upsert.
- **Background tagging (A2):** a delta is tagged `bg` when the owner app is not frontmost at sample time. It is additionally tagged `away` when the screen is locked or the display asleep. Frontmost app and lock/sleep state come from App/Runtime (NSWorkspace, `com.apple.screenIsLocked`) into the engine as a state command.
- **Aggregation key in memory:** (app, remote `IPAddress`, remote port, proto). The host key is assigned only when the minute is emitted (§6).

### Persisted (A2; GRDB migration `net_v1`, `Schema.version` → 2)

```sql
net_host(id INTEGER PRIMARY KEY, host_key TEXT UNIQUE, label TEXT, first_seen INTEGER, last_seen INTEGER)
net_host_ip(host_id INTEGER, ip BLOB, country TEXT, city TEXT, lat REAL, lon REAL,
            last_seen INTEGER, PRIMARY KEY(host_id, ip)) WITHOUT ROWID
net_1m(ts INTEGER, app_id INTEGER, host_id INTEGER, port INTEGER, proto INTEGER,
       rx INTEGER, tx INTEGER, bg_rx INTEGER, bg_tx INTEGER, away_rx INTEGER, away_tx INTEGER,
       conns INTEGER, rtt_wsum REAL, rtt_w REAL,
       PRIMARY KEY(ts, app_id, host_id, port, proto)) WITHOUT ROWID
net_15m(same columns)
CREATE INDEX net_1m_app ON net_1m(app_id);   CREATE INDEX net_15m_app ON net_15m(app_id);
CREATE INDEX net_15m_host ON net_15m(host_id);
net_seen(kind TEXT, key TEXT, first_seen INTEGER, last_seen INTEGER, PRIMARY KEY(kind, key))
  -- kind: apphost (AppKey + host_key) [A2], exec (ExecKey) [A3], listener (ExecKey + proto + bind scope) [A3]
```

**Columns**
- Geo lives per IP (`net_host_ip`), not per host key: a key like "Google" spans many locations.
- `conns` = flows *opened* in the bucket, so rollup sums stay correct. RTT is stored as `rtt_wsum`/`rtt_w` with weight `max(bytes, 1)`; the mean is computed on read; NULL when there are no samples.
- `port` = remote port only. Listeners live only in `net_seen`.

**Writes**
- Only completed minutes are emitted, at minute N+1m+30 s (the grace period for rDNS). At shutdown, the partial minute is written too.
- Every write is `INSERT … ON CONFLICT DO UPDATE SET rx=rx+excluded.rx, …` (additive upsert), via `RecordBatch.net: [NetRow] = []` and `RecordWriter`.
- `net_seen` and known IPs are cached in memory: only new keys are written, and `last_seen` is bumped at most once per day.

**Rollup & retention**
- Separate `NetRollup` pass for `net_1m` → `net_15m`: sums, with its own watermark `MAX(ts) FROM net_15m`.
- `NetRetention` prunes `net_1m` > 26 h and `net_15m` > 7 d.
- Hosts, IPs and `net_seen` rows are pruned when unreferenced by `net_15m` and `last_seen` is older than 30 d.
- `Retention` app-row garbage collection also checks `net_1m`/`net_15m` through the `app_id` indexes, so apps referenced only by net tables are not deleted. Exclusions are keyed by `AppKey` in settings, so they cannot be orphaned.

**Ranges & size**
- 30d range and >7 d history: app level from existing `app_15m.netRx/netTx`. That source only includes apps above the ≥1 KB/s threshold; the rest go into `other`.
- Size estimate: 150–300 active (app, IP-folded host, port) combos/min → `net_1m` ≈ 250–470 k rows plus `net_15m` ≈ 100–200 k rows, about 30–60 MB. The spike verifies this.

**Schema bump:** `user_version` 2. **Consequence:** running an older build afterwards moves the whole history DB aside. This is stated in the ICR and release notes.

**Clear history**
- Delete in chunks of 10 k rows, rounding range edges outward to 15 min.
- Also clear pending aggregates, `NetWindowIndex` and the in-memory seen caches.
- Then `PRAGMA secure_delete=ON` (net deletes), `wal_checkpoint(TRUNCATE)`, `incremental_vacuum`. `All` also runs `VACUUM`, resets `net_seen` and restarts learning (A3).
- **Exclude app:** optionally deletes that app's rows and purges hosts/IPs no other app references.

## 6. Enrichment

### Address scope (`ScopeClassifier`, runs before anything else)
- **Loopback:** 127/8, ::1.
- **LAN:**
  - RFC 1918, 169.254/16, fe80::/10 (zone kept, so `fe80::1%en0` ≠ `%utun3`), fc00::/7;
  - global v6 inside any local interface's on-link prefix.
- **CGNAT/overlay:** 100.64/10 (Tailscale, carrier NAT).
- **Proxy fake-IP:** 198.18/15 (Surge/Clash); labelled "Proxy (fake IP)" with no geo or rDNS.
- **Multicast/broadcast:** 224/4, 255.255.255.255, directed broadcast, ff00::/8.
- **NAT64:** 64:ff9b::/96. The embedded v4 address is extracted and used for ranges and geo.
- Anything else is internet scope. Only internet-scope IPs get rDNS, provider ranges or geo.

### Special traffic
- **iCloud Private Relay:** flows to Apple's relay ingress ranges from relay-using processes are labelled `iCloud Private Relay`. No rDNS (a PTR query to the ISP resolver would leak what Relay hides) and no geo.
- **VPN tunnel carrier:** when a `utun` interface is up, the VPN client's flow on a physical interface to the tunnel server is flagged `tunnelCarrier` and excluded from sums. Detection heuristic is chosen by the spike.
- **Local proxy:** loopback is excluded from totals. The proxy's upstream flows are attributed to the proxy app as normal.

### Host naming chain (`HostResolver`)
1. Non-internet scope: key = scope label (`LAN`, `Loopback`, `CGNAT`, …); IP shown in the connection row.
2. Known range match gives a provider label (`Google`, `Apple`, `AWS us-east-1`, `Cloudflare`, …).
3. **rDNS name validation:**
   - sanitize: lowercase, strip trailing dot, cap length/charset, show punycode for mixed-script IDN;
   - **forward-confirm**: A/AAAA of the name must contain the IP;
   - reject names that claim a known-provider domain while the IP is outside that provider's ranges;
   - a name that fails any check is shown as `(unverified)` and never used as a key.
4. **eTLD+1** of a verified name, using the **ICANN section only** of the PSL. The private section would turn `ec2-…compute-1.amazonaws.com` into a separate host per IP.
5. **Key selection:**
   - if a provider label exists and the verified eTLD+1 is that provider's infrastructure domain (`1e100.net`, `amazonaws.com`, `akamaitechnologies.com`, …; list bundled with the ranges), key = provider label;
   - else key = verified eTLD+1;
   - else provider label;
   - else residential/ISP PTR patterns become `ISP peer (<eTLD+1>)`;
   - else IP.
6. **Stability:**
   - the key is assigned when a minute is emitted, after the 30 s grace;
   - once an IP is stored in `net_host_ip`, its host key is pinned and existing rows are never re-keyed;
   - late rDNS answers only update display names.

### Sources
- **ReverseDNS:** moved to MonitorNet; 4096 entries, 1 h TTL, 20/s token bucket, max 4 concurrent. LRU eviction runs in batches of the oldest 10 % (no O(n) `min` per insert). Its class doc "never in background" is updated. Toggle `network.rdnsEnabled`.
- **KnownRanges:** Apple 17.0.0.0/8, Google `goog.json`, AWS `ip-ranges.json`, Cloudflare, Microsoft, Akamai, Fastly, Meta, Apple Private Relay egress list. `update-ranges.sh` flattens these into sorted, non-overlapping intervals (most specific wins), so the runtime does a single binary search over `IPAddress`.
- **PublicSuffix:** ICANN section only, bundled.
- **PortNames:** bundled IANA subset.
- **MMDBReader:**
  - In-house, read-only, mmap'd, bounds-checked. Validates metadata (type, IP version, record size) before use.
  - Results cached per /24 (v4) and per /48 (v6).
  - Memory reported as `phys_footprint`, not RSS.
- **Geo databases:** A1 ships DB-IP Country Lite `.mmdb` in the bundle. A4 downloads City Lite `.mmdb` into `dataDirectory`, which supersedes it.
- **GeoUpdater (A4):**
  - **Schedule:** NSBackgroundActivityScheduler, `.background` QoS, prefers AC power. Runs when the last update is more than 32 d old.
  - **Download:** `download.db-ip.com/free/dbip-city-lite-YYYY-MM.mmdb.gz`, an undocumented URL. On 404 it falls back to the previous month.
  - **Safety:** caps on compressed and decompressed size (against gzip bombs); streaming gunzip; validation (metadata, canary IP lookups).
  - **Swap:** atomic `rename` into place, never truncating a mapped file in place. The previous file is kept on failure.
  - Settings: toggle (default on), "Update now", last-updated date.
- **SigningInfo:**
  - **Badge:** from the running process's dynamic code (`SecCodeCopyGuestWithAttributes` by pid/audit token + `kSecCSDynamicInformation`, or `csops` status/team id); costs microseconds.
  - **Classification:** `CS_LINKER_SIGNED` → `.linkerSigned` (Homebrew/cargo/go/Xcode builds). Telltale's own process is suppressed.
  - **Notarized:** only when the inspector opens, one job at a time, `.background` QoS, `SecStaticCodeCheckValidity` with `kSecCSDoNotValidateResources | kSecCSNoNetworkAccess`. Stapled tickets only, so no online check.
  - **Cache:** persisted on disk, keyed by cdhash; lookup by (dev, inode, size, mtime).

## 7. Alerts (A3)

- **ExecKey:**
  - Developer ID / Apple-signed: team ID + signing identifier (no path, no cdhash, so it survives updates).
  - Ad-hoc / linker-signed / unsigned: signing identifier + normalized path. Translocation is undone via `SecTranslocateCreateOriginalPathForURL`, and `Cellar/<name>/<ver>` is stripped.
  - Interpreters (python3, node, ruby, perl, osascript, java, sh-family): interpreter + `argv[1]` script path via `KERN_PROCARGS2`.
  - cdhash is kept as event detail only.
- **Rules** (evaluated at each minute emit, including drained closed flows, so short flows are not missed):
  - **First network access:** an ExecKey absent from `net_seen` opens an internet-scope flow.
  - **Unsigned connects:** a `.adhoc` / `.unsigned` executable opens an internet-scope flow; once per ExecKey per day. `.linkerSigned` gets a lower-severity variant, off by default.
  - **New listener:** a listener's (ExecKey, proto, bind scope) changes from absent or loopback to LAN/wildcard. Alerts fire on scope changes, not on each new ephemeral port (dev servers). Apple service listeners are exempt.
- **Learning period:** 24 h of *recorded uptime* spread over ≥ 2 distinct days, from first run or after clear-all. During it, `net_seen` fills silently.
- **Always:** `event` row (kind `network`), sidebar and popover badge dot, timeline tick.
- **OS notifications:**
  - Per-alert toggles, all off by default. Permission is requested on first toggle-on.
  - `UNUserNotificationCenter` lives in the App target behind a `NotificationCommands` closure struct; it traps outside a bundle (swift test, telltale-render). The delegate is set in `AppDelegate` before launch finishes.
  - A click routes to the page with the item selected, through the internal navigation route.

## 8. Performance notes

- **Sensor decode:**
  - Descriptor fields (process, addresses, start) are parsed once per source. Later callbacks read only rx/tx/packets/RTT/TCPState. Raw address bytes (≤ 28 B) are compared with memcmp before re-decoding, because UDP may connect later.
  - Keys are bridged to `CFString` once and read with `CFDictionaryGetValue`. Lock acquisitions are merged to 1–2 per callback.
  - Target: 50–60 % less per-callback cost.
- **`needsDescriptions()`:** tracks an unresolved-source counter instead of an O(n) scan per query.
- **Page not visible:** the engine only appends to the ring and index; no `NetSnapshot`, no rows (following `LiveModel.presenting`).
- **Listening scan:** 30 s cadence while visible, 60 s in background (A3 listener alert). Uses NStat data if the spike shows it suffices.
- **Top talkers:** partial selection. Country aggregation via country code from the cache.

## 9. Testing

- **Unit (TDD):**
  - `ScopeClassifier`: every range in §6, NAT64 extraction, zones.
  - `PublicSuffix`: ICANN-only, `co.uk`, IDN, wildcard rules.
  - `KnownRanges`: flattened intervals, boundaries, misses.
  - `MMDBReader`: fixture DB, malformed and truncated files, v4/v6.
  - `HostResolver`: chain, forward-confirm pass/fail, spoofed provider claim, provider-infra override, ISP peer, pinning.
  - `FlowTracker`: first-sight baseline, wake reset, closed-flow final delta, sensor restart.
  - `NetAggregator`: minute emit + grace, additive upsert rows, `conns` = opened, RTT weights, exclusion drop, bg/away tagging, Relay/tunnel-carrier/loopback exclusion from sums.
  - `NetWindowIndex`: window totals, gaps.
  - `NetRowBuilder`: collapsed children not built, stable ids, closed cap.
  - `ExecKey`: team-signed, translocated, Cellar, interpreter + script.
  - `NetAlerts`: learning by uptime/days, dedupe, listener scope-change only, Apple exemptions.
  - `SigningInfo`: linker-signed classification (fixture binaries).
- **Store:** in-memory `HistoryStore`:
  - `net_v1` migration + `user_version` 2;
  - additive upsert idempotence;
  - `NetRollup` sums + own watermark;
  - retention cutoffs;
  - app GC keeps net-referenced apps;
  - host/IP/seen pruning;
  - chunked clear + range edge rounding;
  - exclude purge.
- **Mocks:** `MonitorMocks.NetworkScenario` with:
  - browser CDN fan-out; `nsurlsessiond` delegation;
  - unsigned and linker-signed binaries;
  - AirPlay `*:5000` and a real `*:8080` listener; wildcard UDP ephemeral;
  - Private Relay flow; VPN carrier + utun flows;
  - closed short flows; unattributed; kernel;
  - spoofed PTR.
- **Snapshots** (`telltale-render`, light and dark):
  - List (live, history), Listening, Map (A4);
  - each inspector variant and every state in §4;
  - popover card, Network page top-5 card.
- **Perf:** `telltale-probe` reports background CPU delta, per-callback decode cost, per-tick enrichment cost, `phys_footprint`, DB size after 24 h. Advisory.

## 10. Rollout

**A1 — Live** (no persistence, no SPEC persistence ruling yet)
1. **Spikes:**
   - NStat listener visibility (TCP Listen, bound UDP) vs `proc_pidfdinfo` (EPERM for root/other users);
   - closed-flow drain;
   - VPN carrier detection;
   - Private Relay ingress attribution;
   - mDNSResponder epid delegation;
   - RTT unit.
2. Artboards in `docs/design`.
3. ICR 017 part 1: page case, `.networkMonitor` demand, `FlowCounter` fields, `closedFlows`, `IPAddress`, `SystemFrame.network`.
4. **Sensor work:** decode-once, closed-flow drain, forced endpoints, local address.
5. **`MonitorNet` pure units:**
   - `ScopeClassifier`, `PublicSuffix`, `KnownRanges`, `PortNames`, `MMDBReader` (Country Lite bundled);
   - `HostResolver`, `FlowTracker`, `NetAggregator` (live only), `NetWindowIndex`, `NetRowBuilder`.
6. **Runtime I/O:** `ReverseDNS` move, `NetEnricher`, `SigningInfo`.
7. **Page:** timeline (live), list + inspector + toolbar + top talkers, Listening.
8. Processes `ConnectionsPanel` link + enrichment; Network page top-5 card.

**A2 — History**
1. ICR 017 part 2 + SPEC ruling (persisted aggregates, background rDNS, budget).
2. Schema `net_v1`, writer upsert, `NetRollup`, `NetRetention`, app GC change, `NetHistoryProvider`.
3. Range picker, history list, timeline backfill + pending-minute merge.
4. `net_seen` apphost + `New` chip + `New since yesterday` preset.
5. Background/away tagging + `Background` chip + inspector shares.
6. Settings › Privacy: clear history, exclusions, rDNS toggle; DB file modes.

**A3 — Alerts**
1. SPEC ruling (Notification Center).
2. Spike: notifications under ad-hoc signing, permission survival across re-sign.
3. `ExecKey`, `NetAlerts`, learning.
4. `HistoryEvent.Kind.network`.
5. `NotificationCommands`.
6. Internal route for notification clicks.
7. Popover mini-card, sidebar badge.

**A4 — Map**
1. SPEC ruling (outside service).
2. `GeoUpdater` (City Lite mmdb).
3. Natural Earth resource.
4. Map view.
5. "My location" setting.
6. Attribution in the map and inspector.

## 11. Later (out of A)

- ASN/org DB
- interface "Via" column + DNS resolver header + metered-network banner
- timeline spike attribution
- parent/launchd attribution for CLI tools
- unusual-upload alert and per-app daily caps
- Listening "reachable from" + macOS firewall state
- keyboard shortcuts and `telltale://` deep links
- long-lived connection chip
- LAN device list
- data-usage report + CSV/JSON export
- saved filters
- mute/ignore list
- real queried domains + TLS SNI + tracker labels (from B)

## 12. Sub-project B handoff

- Tree gets a verdict column (allowed / denied / rule) and an inspector "Create rule…" action.
- B's NetworkExtension layer can supply true queried domains and SNI, which replace the rDNS host naming for new rows.
- B gets its own interview and spec.

## 13. Risks

- **Private API:** NStat is private and can change between macOS releases. The existing sensor already degrades to "unavailable".
- **Accuracy:**
  - Short-lived flows land as pid 0 or unknown and show under the `Unattributed` / `Kernel` rows.
  - Totals stay 4–10 % below `getifaddrs`, because NStat sees TCP/UDP only.
- **Listeners:** root-owned listeners may be invisible. Stated in the UI; the listener alert is incomplete for them.
- **Outbound traffic:** rDNS queries (toggle) and the A4 monthly geo download. Notarization checks are kept offline by flags.
- **Geo accuracy:** poor for anycast/CDN and v6 in DB-IP Lite. Mitigated by `Global` for provider ranges and "approx." city labels.
- **Rules:** VPN carrier and Private Relay detection are heuristics. The spike decides; failure mode is double counting, which gets a visible label.
- **History:** after the schema bump, an older build moves the history DB aside.
- **Privacy:** the history DB reveals browsing destinations. Mitigated by exclusions with purge, secure clear, file modes `0600`/`0700`.
- **Sub-project B under a free team:** a NetworkExtension content filter needs SIP partly off (`systemextensionsctl developer on`) and possibly an AMFI boot-arg. It runs locally only and cannot be distributed.
