# Network Monitor page — design

Date: 2026-09-24 · Status: approved design, pre-plan

## 1. Goal

Add a **Network Monitor** page to the dashboard: a Little-Snitch-style observer that shows every app's live connections (app → remote host → socket), bandwidth over time, where traffic goes on a world map, which processes listen on which ports, and a persisted per-app/per-host history — all from the existing unprivileged NetworkStatistics source.

This is **sub-project A** of two. Sub-project B (firewall: NetworkExtension content filter, allow/deny rules, prompts) gets its own interview, spec and plan after A ships; A is designed so B's verdicts plug into the same page (§10).

Non-goals (v1): blocking/filtering of any kind, real queried DNS names or TLS SNI (need B's packet access), ASN/org database, LAN device list, per-app data-usage report and CSV export, saved filters, mute/ignore list, zoomable street map.

## 2. Decisions (from interview)

| Topic | Decision |
|---|---|
| Scope | Monitor + firewall overall; A (monitor) first, B (firewall) later with its own spec |
| Signing | Free/personal team only. Irrelevant for A; for B it means local-only with SIP partly off (risk, §11) |
| Placement | New sidebar page `Network Monitor`, Activity section. Existing Network page stays (interfaces, throughput, Wi-Fi); its per-app table moves here, replaced by a top-5 card + link |
| Hierarchy | App → host → connection tree |
| Closed connections | Live + recent: closed flows stay dimmed, totals accumulate for the session |
| History | Persisted aggregates per (app, host, remote port, proto) per bucket; no per-socket log |
| Retention | Existing 30 d tier policy (see §5 for the no-raw-tier adjustment) |
| Background capture | Always on; host-level data recorded while the page is closed |
| Timeline | Live last 1 h at 1 s + history ranges 24h/7d/30d; history ranges show app/host rows only |
| Host naming | Reverse DNS (existing cache, now wired) + bundled known-provider IP ranges; real domains/SNI deferred to B |
| Host grouping key | Best name folded to registrable domain (eTLD+1, bundled Public Suffix List), fallback chain (§6) |
| GeoIP | Offline, city-level DB-IP City Lite; downloaded in-app monthly |
| Map | Bundled Natural Earth 110m vector world drawn in SwiftUI `Canvas`; no MapKit |
| Visuals | Scrubbable traffic timeline, world map, inspector panel, top-talkers cards |
| Extra data | RTT/packets (latency + quality), code-signing identity per app |
| Extra views | Listening ports, port/service labels (IANA) |
| Alerts | First network access by an executable, unsigned binary connects, new non-loopback listener. Off by default (per-alert OS-notification toggles); event log + badge always; 24 h learning period |
| Row actions | Copy / reveal in Finder / jump to Processes; external lookup (whois, ipinfo, Shodan) on explicit click; quit / force quit |
| Filtering | Search field, filter chips, sort by rate/total/conns/RTT |
| Integration | Popover mini-card; Processes `ConnectionsPanel` link + enrichment; Network page top-5 card |
| Layout | Timeline strip on top, `List | Map | Listening` switcher, collapsible inspector on the right |
| Privacy | Clear-network-history (by range) + per-app "don't record" exclusion |

Implementation defaults chosen without interview:

- Closed flows stay dimmed for **5 min** before leaving the live list.
- "My location" (arc origin on the map) is a manual city setting, **default none**: arcs hidden, dots still shown. No outbound request to discover the public IP.
- Known-range tables and the Public Suffix List are refreshed by script only (`scripts/update-ranges.sh`), not in-app. Geo DB is the only in-app download.
- History DB file mode `0600`.

## 3. Architecture

- **Approach:** extend the existing pipeline. The single long-lived NetworkStatistics manager in `NStatSensor` stays the only source (creation 0.3–1.3 s, query ~25 ms — never duplicated). Rejected: a second NStat pipeline for the page (double cost, two truths for bytes); shelling out to `nettop`/`lsof` (CPU, fragile, no RTT).
- **Sensor (`MonitorSensors/Network/NStatSensor.swift`)**: always decodes remote address/port, TCP state, interface, RTT avg/min/variance, packets and `startAbsoluteTime` (today gated behind `.connections`). Listening sockets: use NStat sources with `TCPState == Listen` and bound UDP sources if NStat reports them; otherwise add a `proc_pidfdinfo` socket enumerator. Decided by spike (§9 step 1).
- **Demand**: new `SamplingDemand.networkMonitor`, set while the page is visible. Lifts the per-inspected-app connection filter in `FrameAssembler` and enables the 1 s live timeline. Background (10 s cadence) keeps address fields on for aggregation.
- **New SPM target `MonitorNet`** (depends on `MonitorModel`; no UI). Units, each testable alone:
  - `FlowTracker` — stable flow identity across ticks (NStat source ref + start time), close detection, 5-min dim window, folds closed bytes into `NStatFlowTable` totals.
  - `HostResolver` — naming chain (§6), async, cached.
  - `PublicSuffix` — eTLD+1 from bundled PSL.
  - `KnownRanges` — sorted range table from bundled provider JSON, longest-prefix match.
  - `PortNames` — bundled IANA subset.
  - `GeoDB` — memory-mapped compact binary lookup; `GeoConverter` (CSV → binary); `GeoUpdater` (monthly download).
  - `SigningInfo` — Security.framework static-code checks, cached by path + mtime.
  - `NetAggregator` — builds the live app → host → flow tree for the current window/filters and emits per-minute history records.
  - `NetAlerts` — rules over the `net_seen` diff each flush.
- **Enrichment actor**: all lookups (rDNS, geo, ranges, signing) run on their own actor, off the sampling queue. Frames never block on enrichment: rows render the IP first and fill in when resolved. Only internet-scope IPs go to rDNS; rDNS rate-limited to 20 lookups/s.
- **Models in `MonitorModel/Network/`** (§5). **UI boundary**: `NetworkMonitorModel` in `MonitorLive` (live tree, 1 h timeline ring of 3600 points, selection, filters) + `NetworkMonitorActions` closure struct (copy, reveal, lookup, quit, jump to Processes, clear history, exclude app).
- **UI in `MonitorScreens/Pages/NetworkMonitor/`**, snapshot-rendered via `telltale-render`.
- **Navigation / ICR**: new `DashboardPage.networkMonitor` touches `Navigation.swift`, `DashboardRoot.swift`, `Sidebar.swift`, `Sampling.swift` (demand switch), `ScreenCatalog.swift`. Requires an ICR (ARCHITECTURE §9) and a SPEC ruling: SPEC currently says connections are live-only; this design persists connection *aggregates*.
- **Signing**: no change for A (no new entitlements; unsandboxed ad-hoc build). Notification permission under ad-hoc signing verified by spike.
- **Cost budget**: background < 0.5 % CPU, reported by `telltale-probe` — advisory, not a gate.

## 4. Page layout

### Header
Title, range picker `Live 1h | 24h | 7d | 30d`, pause-live toggle, clear-history menu (last hour / day / all).

### Timeline strip
Stacked in/out area chart. Live: 1 s points over the last hour. History: 1 m / 15 m buckets. Drag selects a window → everything below filters to it; double-click clears. Hover shows rate and time. Alert ticks on the time axis.

### Toolbar
`List | Map | Listening` switcher · search (app, host, IP, CIDR, port, country, provider label) · filter chips: TCP / UDP, IPv4 / IPv6, state (active / closed / listen), scope (internet / LAN / loopback) · sort menu (rate, window total, connection count, RTT).

### Top talkers
Three compact cards — apps, hosts, countries — top 5 by bytes in the current window. Clicking an entry applies it as a filter.

### List (tree)
- **App row**: icon, name, signing badge (Apple / team name / ⚠ unsigned or ad-hoc), ↓/↑ rate, window total, connection count, sparkline.
- **Host row**: best name, provider label, flag + city, rate, window total, connection count, median RTT.
- **Connection row**: `local:port → remote IP:port`, service name, proto, state, interface, RTT, bytes, age. Closed rows dimmed with "closed 2m ago".
- History ranges show app and host levels only, with a note that per-connection detail is live-only.
- Flows the kernel could not attribute appear under an `Unattributed` app row.

### Map
Canvas world map (Natural Earth 110m). One dot per city, area ∝ bytes in window. Arcs from "My location" when set. Hover: city, hosts, apps. Click a country → filter. Respects window and filters.

### Listening
Table: process, proto, bind address, port, service, since. `*` / `0.0.0.0` / `::` binds highlighted with a warning tint; loopback-only binds plain.

### Inspector (collapsible, right)
- **App**: path, signing identity, notarized flag, pid(s), totals today / 7 d, top hosts, first seen. Actions: reveal in Finder, quit / force quit, open in Processes, don't record.
- **Host**: rDNS name, provider label, known IPs, geo, remote ports, apps using it, first seen, RTT stats. Actions: copy IP / host / `IP:port`, look up in whois / ipinfo / Shodan (opens browser; sends the IP to that site).
- **Connection**: every field + byte sparkline. Actions: copy.

### States
- NetworkStatistics unavailable → empty-state card with the reason; page disabled.
- Geo DB missing or downloading → flags hidden, map shows download button / progress; list unaffected.
- Global sampling paused → banner; timeline frozen.
- Empty filter result → "No matches" + clear filters.
- Excluded app → shown live with a "not recorded" badge; absent from history.
- Learning period (first 24 h) → banner with countdown; alerts suppressed.

### Outside the page
- **Popover mini-card**: live connection count, top 3 talkers, alert dot; click opens the page.
- **Processes `ConnectionsPanel`** (`AppInspector.swift`): host names, flags, "Open in Network Monitor".
- **Network page**: per-app table replaced by top-5 apps card + "Open Network Monitor →".
- **Sidebar**: trailing value = live connection count; badge dot for unseen alerts.

## 5. Data model

### Live types (`MonitorModel/Network/`)
- `NetFlow`: flow id, pid, epid, `AppKey`, proto, local / remote `IPEndpoint`, state (TCP state or UDP bound), interface, rx / tx bytes, packets, RTT avg / min / variance, `openedAt`, `closedAt?`.
- `NetHost`: `hostKey`, display name, provider label, `GeoInfo?` (country, city, lat, lon), IP set, scope (loopback / LAN / internet).
- `SigningIdentity`: `.apple`, `.developerID(team:name:)`, `.adhoc`, `.unsigned`; plus `notarized: Bool`.
- `ListeningSocket`: pid, `AppKey`, proto, bind address, port, since.
- Tree nodes `NetAppNode` → `NetHostNode` → `NetFlow`, rebuilt per frame for window + filters.
- `NetTimelinePoint(ts, rx, tx)`; ring of 3600 in `NetworkMonitorModel`.

### Persisted (GRDB migration `net_v1`)

```sql
net_host(id INTEGER PRIMARY KEY, host_key TEXT UNIQUE, label TEXT,
         country TEXT, city TEXT, lat REAL, lon REAL, first_seen INTEGER)
net_host_ip(host_id INTEGER, ip BLOB, last_seen INTEGER,
            PRIMARY KEY(host_id, ip)) WITHOUT ROWID
net_1m(ts INTEGER, app_id INTEGER, host_id INTEGER, port INTEGER, proto INTEGER,
       rx INTEGER, tx INTEGER, conns INTEGER, rtt_ms REAL,
       PRIMARY KEY(ts, app_id, host_id, port, proto)) WITHOUT ROWID
net_15m(same columns)
net_seen(kind TEXT, key TEXT, first_seen INTEGER, last_seen INTEGER,
         PRIMARY KEY(kind, key))
  -- kind: exec (path + team id / cdhash), host (host_key), listener (exec + proto + bind + port)
net_exclude(app_id INTEGER PRIMARY KEY)
```

- `app_id` references the existing `app` table.
- **No per-tick raw tier** for network: per-host rows every second bloat the DB, and the in-memory 1 h ring covers second-level detail. The 24h range reads `net_1m` (kept 7 d); `net_15m` kept 30 d. Pruned by existing `maintain(now:)`.
- Rollup: bytes and conns summed, RTT byte-weighted mean.
- `port` = remote port only (local ephemeral ports dropped). Listeners live only in `net_seen`.
- Alerts reuse the existing `event` table, kind `network`.
- Size estimate ≈ 50 active (app, host, port) combos/min → ~72 k rows/day → ~30–40 MB for 7 d of `net_1m`. Verified by spike.

### Recording flow
`NetAggregator` accumulates deltas in memory per (app, host, port, proto) per minute → on minute boundary or store flush emits `RecordBatch.net` rows → excluded apps dropped before the batch. Clear history deletes a range from `net_*`; "all" also resets `net_seen`, restarting the learning period.

## 6. Enrichment

### Host naming chain (`HostResolver`)
1. Scope check: loopback / LAN (RFC 1918, link-local, ULA, multicast/mDNS) → key = IP, label `Loopback` / `LAN`.
2. Known range match → provider label (e.g. `Google`, `Apple`, `AWS us-east-1`, `Cloudflare`).
3. rDNS name → eTLD+1 via PSL.
4. Key selection: if a provider label exists **and** the rDNS eTLD+1 is that provider's infrastructure domain (`1e100.net`, `amazonaws.com`, `akamaitechnologies.com`, …; list bundled with the ranges), key = provider label; else key = rDNS eTLD+1; else provider label; else IP.
5. Expanding a host shows its individual IPs and full rDNS names.

### Sources
- **rDNS**: existing `ReverseDNS` cache raised to 4096 entries, 1 h TTL; wired so `ConnectionSample.remoteHost` is finally set.
- **Known ranges**: Apple 17.0.0.0/8, Google `goog.json`, AWS `ip-ranges.json`, Cloudflare, Microsoft, Akamai, Fastly, Meta → bundled JSON compiled to sorted ranges. `scripts/update-ranges.sh` refreshes ranges + PSL.
- **PortNames**: bundled IANA subset (common services).
- **GeoDB**: binary of sorted `[start, end, cityIdx]` for v4 and v6 + city string table, memory-mapped from Application Support.
- **GeoUpdater**: checks on the 2nd of each month (DB-IP publishes on the 1st). HTTPS download of `dbip-city-lite-YYYY-MM.csv.gz` → background convert → atomic swap, previous copy kept on failure. Settings: toggle (default on), "Update now", last-updated date. CC-BY attribution in About. First launch has no DB until the first download.
- **SigningInfo**: `SecStaticCodeCreateWithPath` + `SecCodeCopySigningInformation` (team, identifier, flags); notarized via `SecStaticCodeCheckValidity` with the notarization requirement. Cached by path + mtime, computed on first sight of an executable.

## 7. Alerts

- **First network access**: an exec key absent from `net_seen` opens an internet-scope flow.
- **Unsigned connects**: `.adhoc` / `.unsigned` executable opens an internet-scope flow; once per exec per day.
- **New listener**: new (exec, proto, port) bound to a non-loopback address.
- **Learning period**: 24 h from first run (or after clear-all). `net_seen` fills silently; no alerts.
- **Always**: `event` row, sidebar + popover badge dot, timeline tick.
- **OS notifications**: per-alert toggles in settings, all off by default. Permission requested on first toggle-on. Clicking a notification opens the page with the item selected.

## 8. Testing

- **Unit (TDD)**: `FlowTracker` (identity across ticks, close/dim timing, fold into totals) · `HostResolver` (chain incl. provider-infra override) · `PublicSuffix` (`co.uk`, IDN, wildcard rules) · `KnownRanges` / `GeoDB` (v4/v6 boundaries, misses) · `GeoConverter` on a tiny fixture CSV · `NetAggregator` (minute bucketing, exclude filter, RTT weighting) · `NetAlerts` (learning period, dedupe, once-per-day).
- **Store**: in-memory `HistoryStore` — `net_v1` migration, rollup `net_1m` → `net_15m` byte sums, retention prune, clear by range.
- **Mocks**: `MonitorMocks.NetworkScenario` — browser CDN fan-out, unsigned binary, listener on `*:5000`, UDP mDNS, closed flows, unattributed flow.
- **Snapshots** (`telltale-render`, light + dark): List (live + history), Map, Listening, each inspector variant, every state in §4, popover card, Network page top-5 card.
- **Perf**: `telltale-probe` reports background CPU and per-tick enrichment cost. Advisory.

## 9. Rollout order

1. Spikes: NStat listener visibility (TCP Listen, bound UDP) vs `proc_pidfdinfo`; `net_1m` size over a real day; `UNUserNotificationCenter` under ad-hoc signing.
2. Artboards in `docs/design`.
3. ICR (page case, `.networkMonitor` demand, `net_v1` schema) + SPEC ruling on persisting connection aggregates.
4. `MonitorNet` data units: `PublicSuffix`, `KnownRanges`, `PortNames`, `GeoDB` + `GeoConverter`, `SigningInfo`, `HostResolver`.
5. Sensor changes + `FlowTracker` + `NetAggregator` → live model + timeline.
6. Page: List + inspector + toolbar + top talkers.
7. Store tables, history ranges, clear history, exclude app.
8. Map.
9. Listening view.
10. Alerts + notifications.
11. Popover card, Processes link, Network page top-5 card.
12. `GeoUpdater`.

## 10. Later (out of v1)

ASN / org DB · LAN device list · per-app data-usage report + CSV/JSON export · saved filters · mute / ignore list · real queried domains + TLS SNI (from B) · **sub-project B firewall**: verdict column (allowed / denied / rule) in the tree and a "Create rule…" action in the inspector; B gets its own interview and spec.

## 11. Risks

- NetworkStatistics is private; can change across macOS releases. Existing sensor already degrades to "unavailable".
- Short-lived flows land in pid 0 / unknown → `Unattributed` row; totals stay 4–10 % below `getifaddrs` (TCP/UDP only).
- City DB ≈ 40–60 MB in Application Support (not the bundle); monthly download is the app's only outbound request.
- rDNS lookups hit the system resolver; rate-limited to 20/s, internet scope only.
- Always-on address decode raises background CPU; measured, advisory.
- History DB reveals browsing destinations → exclude-app, clear history, file mode `0600`.
- rDNS names for CDNs are often meaningless; mitigated by known-range labels until B supplies real domains.
- Sub-project B under a free team: NetworkExtension content filter needs SIP partly off (`systemextensionsctl developer on`) and possibly an AMFI boot-arg; local-only, not distributable.
