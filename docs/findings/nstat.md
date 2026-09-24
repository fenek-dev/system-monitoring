# M0 Findings — NetworkStatistics (Task 7)

## nstat — NetworkStatistics (per-app + per-connection network)
- Status: working. `NStatManagerCreate`/`AddAllTCP`/`AddAllUDP`/`QueryAllSources(Descriptions)` all behave as reverse-engineered. Link flag (`-F/System/Library/PrivateFrameworks -framework NetworkStatistics`, already in `Package.swift`) worked unmodified, no changes needed there.
- Desc keys (== count keys, same dictionary shape for both callbacks): `ChannelArchitecture, durationAbsoluteTime, epid, eupid, euuid, fuuid, ifWiFi, interface, localAddress, processID, processName, provider, receiveBufferSize, receiveBufferUsed, remoteAddress, rttAverage, rttMinimum, rttVariation, rxBytes, rxCellularBytes, rxPackets, rxWiFiBytes, rxWiredBytes, startAbsoluteTime, trafficClass, txBytes, txCellularBytes, txPackets, txWiFiBytes, txWiredBytes, uniqueProcessID, uuid`.
  - Byte/packet counters (`rxBytes`/`txBytes`, plus per-medium `rxWiFiBytes`/`rxCellularBytes`/`rxWiredBytes` and tx equivalents) are present in **both** the description and counts blocks.
  - The key list above was captured from the *first* source encountered, which happened to be a UDP flow (`cloudd`). TCP flows carry one extra key not in that list: **`TCPState`** (confirmed by instrumenting a TCP source specifically: `state key found: TCPState (provider=TCP)`). UDP sources have no state key. So don't trust a single sampled key list as exhaustive — key sets differ by provider.
- Remote/local address key + type: **`remoteAddress`** / **`localAddress`**, both `CFData` wrapping a raw `sockaddr` (confirmed via hex dump, e.g. `length = 16, bytes = 0x1002da0ec0a801400000000000000000` — `sa_len=0x10`, `sa_family=0x02` (`AF_INET`), decodes to a valid `sockaddr_in`). No extern `CFStringRef` symbols were guessed for these (or for `TCPState`) — the header only declares the 5 keys nettop is known to export; the rest are discovered at runtime via case-insensitive substring match over `allKeys` (`remote`/`local`/`state`) and decoded manually (`sa_family_t` at offset 1 → `AF_INET`/`AF_INET6` → `inet_ntop` + big-endian port). This avoided any risk of linking against a wrong/guessed private symbol name.
  - `TCPState` is an `NSNumber` matching the XNU `tcp_fsm.h` ordering (`CLOSED=0 … TIME_WAIT=10`); mapped locally to strings, not sourced from the framework.
  - Decoded addresses were sanity-checked against real traffic: e.g. `claude` (this CLI's own network use) connecting to `160.79.104.10:443` and `34.149.66.165:443` — consistent, stable Anthropic API IPs across every run, in `Established` state.
- Counters in description or counts block? **Both** — the brief's "newer OSes may put byte counters in the description too" holds on this OS (macOS 26.5-class build): the description block always carried populated `rxBytes`/`txBytes`, and the counts block also fires with fresh values. Removed-source handling: `NStatSourceSetRemovedBlock` fires and the spike's handler correctly evicts the source from the dictionary (no leaks/crashes observed across ~4 runs with churn).
- Query cost: first `query()` (descriptions + counts together, ~130-190 live sources): **21-28 ms**. Second `query()` after a 2s gap: essentially the same, **~21 ms**. Cheap enough to poll every 1-2s from a real app.
- Callbacks on provided queue? Yes — all `added`/description/counts/removed blocks fired only on `q` (the serial queue passed to `NStatManagerCreate`); no cross-thread races observed, consistent with the brief's assumption that `NStatManagerCreate`'s `queue` parameter governs callback dispatch.
- Steady-state CPU: measured via `ps -o %cpu -p <pid>` once/2s for 10s with the manager alive but **no further queries issued** (added/removed/counts callbacks may still fire on their own). Result: **~0.0-0.3% CPU**, average ~0.04-0.06% across three separate 10s windows. NStat does not appear to poll/push continuously in a way that costs meaningful CPU when idle; it does not need to be torn down between polls.
- Per-connection sample (pid, process, proto, remote ip:port, TCP state, rx/tx): worked as intended, e.g.:
  ```
  pid=58909 claude proto=TCP local=192.168.1.64:54297 remote=160.79.104.10:443 state=Established ↓1.1 KB/s ↑0.0 KB/s
  pid=54984 Discord Helper (Renderer) proto=UDP local=0.0.0.0:59639 remote=- state=? ↓320.9 KB/s ↑1.1 KB/s
  ```
  UDP sources correctly show `state=?` (no `TCPState` key present) and often `remote=-` for an unconnected/wildcard-bound socket (`0.0.0.0:port`).
- System-wide cross-check via `getifaddrs` (sum of `if_data.ifi_ibytes`/`ifi_obytes` over all `AF_LINK` interfaces, same 2s window as the per-app deltas): NStat's summed per-app rate tracks the interface totals to within ~4-10%, e.g. one run: getifaddrs ↓324.5 KB/s ↑5.0 KB/s vs NStat sum ↓312.6 KB/s ↑1.3 KB/s. The gap is expected — `getifaddrs` counts all L2 traffic on every interface (broadcast/multicast, ICMP, ARP, loopback/VPN `utun` double-counting, protocol headers) while NStat only tracks TCP/UDP flows it's attached sources to.
- Accuracy vs `nettop`: matched. Concurrent `nettop -P -L 2 -J bytes_in,bytes_out -s 2` run alongside the spike identified the same top downloader, `Discord Helper .54984` (`bytes_in=7562354` in nettop's window) as the spike's #1 ranked app (`Discord Helper (Renderer) [54984] ↓309.1 KB/s`) — same PID, same relative magnitude/order.
  - Note: the brief's suggested load generator (`curl … speed.cloudflare.com/__down?bytes=...`) did **not** produce visible traffic in this sandbox — Cloudflare returned `http_code=403` with ~1 byte downloaded (network egress is filtered/blocked here). Validation instead relied on ambient real traffic (this CLI's own Anthropic API connections, Discord's Renderer helper, Telegram, Browser Helper), cross-checked against both `getifaddrs` and `nettop` as above — all three agree on the same top talkers.
- Gotcha — wraparound in naive delta-by-pid aggregation: one run produced a nonsensical `syspolicyd … ↑9007199254740992.0 KB/s` (`≈2^63/2048`). Cause: the per-pid rate calc does `Double(v.1 &- o.1) / 2048` (wrapping subtract) assuming counters only increase between the two snapshots; if a source is removed and a *new* source for the same pid is added mid-window with a lower cumulative counter (common — e.g. a short-lived UDP/TCP flow closing and a new one opening), the wrapping subtraction underflows to a huge `UInt64` near `UInt64.max`. This also poisoned that run's "sum of per-app rates" cross-check total. **Fixed in Fix round 1** below (removed-source bytes are folded into a persistent accumulator instead of just vanishing, which makes the per-pid total monotonic and eliminates this underflow).

## Fix round 1 (reviewer: 2 Important, 2 Minor)

### 1. Removed-source accounting (Important) — fixed
Original bug: `NStatSourceSetRemovedBlock(src) { sources[src] = nil }` just dropped the source; any bytes it carried that hadn't been folded into a `perPid()` sum yet were lost the moment the connection closed, and (as the gotcha above shows) could even underflow a delta calc into a garbage huge number.

Fix (`Spikes/Sources/spike-nstat/main.swift`):
- Added a persistent `retired: [Int64: (name: String, rx: UInt64, tx: UInt64)]` accumulator alongside the live `sources` dictionary.
- `NStatSourceSetRemovedBlock` now folds the source's last-known `rx`/`tx` into `retired` (keyed as below) *before* dropping it from `sources`.
- **Production requirements / key choice**: keyed by **`uniqueProcessID`** (a key present in the description dict — Darwin's kernel-assigned unique-pid value, immune to pid reuse), falling back to raw `pid` only if `uniqueProcessID` wasn't resolved before the source retired. This was chosen over "pid + start time" because `uniqueProcessID` is already supplied by NStat itself and does the same job (disambiguating pid reuse) with no extra API calls.
- `perPid()` is now **live + retired**: it sums each currently-attached source's cumulative counters *and* every retired bucket, grouped by the same `uniqueProcessID`/pid key. A new `perName()` on top groups `perPid()` by process name (used by the churn test below, since each churn-generating `curl` invocation is a distinct pid).
- Edge case found and left as-is (documented, not fixed): a source that is added and removed so fast its description block never fires still gets its bytes retired, but under `pid=0, name="?"` (identity fields never resolved). Bytes aren't lost, but they land in an "unknown" bucket rather than the correct app. Production code should keep an explicit unattributed/`unknown` bucket for this rather than trying to eliminate it — some connections are simply too short-lived to resolve.
- **Verified with churn** (see full run in "Verification" below): a tight loop of `curl -sI --max-time 2 https://example.com` (new pid every invocation, ~10 invocations/sec) drove 1799 source retirements over 165s. The `curl` bucket's total (`perName()["curl"]`, rx+tx) was sampled every 15s and was **strictly non-decreasing across all 12 samples** (705,993 B → 1,425,649 B → … → 8,378,675 B) — no drops, confirming closed-connection bytes are retained rather than lost.
- **Remaining concern (not fixed in this round)**: `retired` itself is **never pruned** — every distinct pid/`uniqueProcessID` that has ever existed during the run gets a permanent entry. This is fine for grouping by stable, long-lived app identity, but under this spike's synthetic per-invocation-pid churn (1799 distinct curl processes in 165s) it produces 1799 permanent dictionary entries; see the memory-growth data below, which shows RSS tracking `retired`'s size, not `sources`' (which stayed flat at ~150-170). **A production implementation must bound this** — either (a) periodically reconcile `retired`'s keys against a live pid/uniqueProcessID set (e.g. via `proc_listallpids`) and evict entries for processes confirmed gone once their bytes have been reported/persisted upstream, or (b) key retirement accumulation by process **name** (or responsible-pid group, per Task 1's grouping) instead of by raw per-launch pid, so the table's size is bounded by "distinct apps ever seen" rather than "every short-lived process instance ever seen." Option (b) is simpler and is what the real per-app network UI almost certainly wants anyway (Task 1's Chrome/Electron helper-collapsing precedent applies here too).

### 2. Memory growth (Important) — measured, growth found and explained
Ran the manager for ~3 minutes (180s) under the same curl churn, sampling `ps -o rss= -p <pid>` every 15s:

| t (s) | RSS (KB) | live sources | retired entries | curl total (B) |
|---|---|---|---|---|
| 15  | 8960  | 159 | 166  | 705,993 |
| 30  | 9056  | 151 | 315  | 1,425,649 |
| 45  | 9376  | 151 | 450  | 2,075,469 |
| 60  | 9520  | 151 | 599  | 2,781,991 |
| 75  | 9744  | 154 | 752  | 3,499,882 |
| 90  | 10128 | 160 | 909  | 4,230,133 |
| 105 | 10192 | 167 | 1055 | 4,908,137 |
| 120 | 10288 | 169 | 1222 | 5,621,558 |
| 135 | 10320 | 158 | 1373 | 6,337,525 |
| 150 | 10656 | 151 | 1523 | 7,047,865 |
| 165 | 11104 | 153 | 1671 | 7,754,404 |
| 180 | 11136 | 151 | 1799 | 8,378,675 |

- **RSS trend**: +2176 KB (8960 → 11136 KB) over 180s, growing roughly linearly, tracking the `retired` entry count (166 → 1799, +1633) almost 1:1 in shape — **not** the `live sources` count, which stayed flat/bounded at 151-169 throughout. This confirms the live-source side of the design (the `sources` dictionary) is well-behaved under churn; the growth is entirely attributable to the never-pruned `retired` accumulator described above.
- At this rate (~12 KB/s under a synthetic ~10 new-processes/sec churn, an aggressive rate unlikely in normal desktop use), the growth is modest over 3 minutes but is **structurally unbounded** over a long-running app's lifetime (hours/days) if left as raw per-pid retirement. This is the concrete case for fix (a) or (b) above before shipping — it is a real, if slow, leak as currently written, not a one-off spike artifact.

### 3. Thread-safety claim (Minor) — confirmed, not just inferred
Added `dispatchPrecondition(condition: .onQueue(q))` as the first line of all four callbacks (`added`, description block, counts block, removed block). This traps immediately (fatal error) if NStat ever invoked a callback off the requested queue. Across every run in this task (baseline + all fix-round-1 verification runs, including the 3-minute churn run with ~1800 add/remove cycles), **zero traps fired** — the "callbacks land only on the queue passed to `NStatManagerCreate`" claim is now a confirmed, tested invariant for this OS build, not an inference from the absence of observed races.

### 4. Manager creation cost (Minor) — measured
Measured wall-clock time from `NStatManagerCreate` + `AddAllTCP`/`AddAllUDP` until the initial "added" callback flood goes quiet (no new source added for 300ms):
- Run 1: **0.320s** for 150 initial sources.
- Run 2 (fix-round-1 full run): **1.250s** for 166 initial sources.
- Both are one-time costs at manager creation, roughly proportional to the number of pre-existing TCP/UDP sockets on the system at that moment (not to load or ongoing traffic).
- **Recommendation, stated explicitly**: create **one** `NStatManagerRef` for the app's entire lifetime (or at least the lifetime of its network-monitoring feature) and reuse it for every poll via `NStatManagerQueryAllSources(Descriptions)`. Do **not** recreate the manager per poll — a per-poll create would pay this ~0.3-1.3s "initial flood" cost (plus the query cost) on every single sample, which is 1-2 orders of magnitude worse than the ~20-35ms steady-state `query()` cost measured earlier, and would also mean losing all `retired` accounting between polls (defeating fix #1).

### Repro
```
cd Spikes
swift build --scratch-path .build-nstat
.build-nstat/arm64-apple-macosx/debug/spike-nstat
```
(`swift run --scratch-path .build-nstat spike-nstat` also works.) No load generator needed in a normal (non-sandboxed) environment — `nettop -P -L 2 -J bytes_in,bytes_out -s 2` run concurrently is the accuracy check.

The default run takes ~3.5-4 minutes (10s idle-CPU check + ~3min churn/memory check, the latter spawning a background `curl` loop against `https://example.com`). Set `NSTAT_QUICK=1` in the environment to skip both long-running checks and exit right after the core per-app/per-connection/`getifaddrs` output (~10-15s total) for fast iteration.
