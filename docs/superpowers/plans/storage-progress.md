# Storage & Cleanup — progress

Spec: `docs/superpowers/specs/2026-09-24-storage-cleanup-design.md`
Plan: `docs/superpowers/plans/2026-10-04-storage-cleanup.md` (pending)
Integration branch: `feat/storage` (worktree `../telltale-storage`, from dev fa55ba7). Mixer WIP on dev untouched.

User decisions (2026-10-04): all 12 steps; no separate artboards — agent renders page via telltale-render and reviews; signing = commit example only (no Team ID); Codex reviews per wave.

## Waves
- [ ] W0: plan (opus) + spikes (sonnet) → findings `docs/findings/storage-spikes.md`
- [ ] W1: foundation — ICR 016, SPEC/ARCH/DESIGN edits, signing, `model:` commit, MonitorDiskTools target skeleton
- [ ] W2 (parallel): scanner+cache+probe · classifier · cleaner+undo+in-use · UIKit
- [ ] W3: runtime + StorageModel + StorageActionsLive + mocks
- [ ] W4: page UI + snapshots + sidebar/popover; screenshots
- [ ] Final review + merge-to-dev decision (ask user)

## Agents / worktrees
- W0 planner (opus, bg) — writes plan on feat/storage
- W0 spikes (sonnet, bg) — /tmp/storage-spikes → docs/findings/storage-spikes.md

- Plan review r1: Codex gpt-6-astra xhigh, clientRequestId storage-plan-review-r1 → 14 P1/16 P2; all accepted (Trash/undo races scoped by threat model: no hostile same-user process). Planner resumed to revise.
- Mixer @unchecked fix (user: fix properly): sonnet agent, worktree ../telltale-mixer-fix, branch fix/mixer-unchecked → merge to dev, rebase feat/storage

- Plan review r2 (storage-plan-review-r2): 13/14 P1 resolved; #6 root-ancestor chain + new P1 per-volume Trash undo → fixed by orchestrator a0a0a69. Review rounds closed.
- W1 (opus, bg): worktree ../telltale-storage-w1, branch ws/storage-w1, progress docs/superpowers/plans/progress/W1.md

## Done
- Spikes a550db4; plan a9b430c (ICR 018, DESIGN §3.17; app now Warden)
- 2026-10-04: Mixer committed on dev (67af40f); feat/storage rebased onto it. Deployment target now macOS 15 (macOS-14 fallbacks moot). User granted FDA to /Applications/Warden.app.

- W1 done on ws/storage-w1 (c1cf31b..3df64bc, 5 commits), ci.sh OK, not merged/reviewed yet. Interface deltas in progress/W1.md. Note for W2d: widen component-icons gallery strip (GallerySamples.swift) — overlay+volume icons clipped.

## Next
- User said continue. Rule change: opus writes briefs, sonnet implements.
- Running: W1 Codex review (storage-w1-review-r1, astra xhigh); opus writing W2a–d briefs → docs/superpowers/plans/briefs/W2*.md on ws/storage-w1.
- Briefs done 988a27d. Decisions: per-app group rows owned by W3a (StorageModel builds grouped lines; CleanupItem.parentID nil from W2b); runningApp flag set by W3b; cross-volume staging = skip (plan wins over spec).
- W1 review r1: 5 P1 / 8 P2 / 1 P3, all accepted. Hard links flagged twice → single redesign (max nlink, occurrences w/ real depth, credit transfer on removal, private bytes+provenance, union reclaim). W1 opus agent resumed to fix (context + subtle). Round 2 only if verified P1s remain.
- W1 fixes c0be58c (ci OK). W1 review r2 running (storage-w1-review-r2, astra high). Last round per rules.
- W1 r2: P1 1–5 resolved; 3 new P1s all in overlay incremental bookkeeping → overlay flagged twice → declarative recompute redesign + seeded randomized ref-model test (W1 opus agent, ws/storage-w1). No further W1 review round (max 2); covered by final review.
- W1 merged into feat/storage @ c0be58c. W2 worktrees ../telltale-storage-w2{a,b,c,d}.
- Running (sonnet): W2a scanner, W2b classifier, W2d UIKit. W2c (cleaner) starts when overlay redesign done (4-agent cap).
- Overlay redesign 64c8bf1 merged into feat/storage (ci OK; 150-seed ref-model test). Known limit: renamed undo next to recreated dir of same node merges display.
- W2c (sonnet) started on ws/storage-w2c @ 64c8bf1. W2a/b/d based on c0be58c → rebase onto feat/storage at merge.
- W2d done (rebased onto feat/storage, 5 commits ..93e8b59; ci OK; renders inspected). Codex review storage-w2d-review-r1 running.
- W2d review: 1 P2 (checkbox dbl-click activates row) fixed 5495e0d (gestures moved to row background layer; no interaction harness → no test). MERGED into feat/storage. W4 live check: clicking row text still selects/double-click drills; checkbox click doesn't.
- W2b done (rebased, ..4d0b962, ci OK). Codex review storage-w2b-review-r1 (astra xhigh) running. Simulator row nodeID nil → told W2c.
- W2b review r1: 7 P1 / 4 P2 / 2 P3, all reproduced+accepted → fixed cc58f3a..4456a9b (ci OK). r2: 5/7 resolved, #4/#6 redesigned (path check per UDID; unconditional unreadable bit) b005070. W2b MERGED (d622d4f). Reviews closed.
- W2a done (438f412..1b582d6 rebased d622d4f; ci OK; 201k entries/s release, cache load 50 ms/474k nodes). ISSUE: `--scan ~` hangs — workers blocked in openat on ~/Library/Containers/com.apple.Family/Data (TCC, no FDA). Review r1: 5 P1/12 P2/2 P3 accepted → W2a resumed. TCC decision: FDA probe first; without confirmed FDA, foreign Containers/Group Containers restricted without opening; no helper process (v1). Builder addLink gets optional depth override. Fixes d32c471 (`--scan ~` no FDA: 6.2M entries 31 s, 1012 restricted). W2a MERGED (ci OK incl. cleaner+model suites after rebase; stale CPrivate ModuleCache needed clearing). r2: P1-4/5 resolved; P1-1/2/3 not → redesign (TCC path-rule policy w/ promptMode allow|never, GUI allows Desktop/Docs/Downloads/iCloud/volumes prompts, restricts containers+category data; cancel returns immediately; cache recompute-derived + sidecar mutation-log replay). W2a resumed; no more rounds. DECISION to report to user: GUI prompts for Desktop/Documents/Downloads without FDA.
- W2a r2 fixes a5f7bed → MERGED as 7fb86e3 (ci OK). `--scan ~` .never: 3.15M entries 16.4 s, 1014 restricted (Desktop/Docs/Downloads skipped in CLI). Cache schema 2 (rebuild on load, 148 ms). Reviews closed.
- W3b done ws/storage-w3b ..94a436b (ci OK). Review r1: 1 P1/8 P2/1 P3 accepted → W3b resumed (rebase onto 7fb86e3, promptMode .allow, FDA inconclusive=false). Open: FDA banner inconclusive=granted vs policy inconclusive=not; 200 ms sleep test; promptMode not adopted.
- W3b fixes a8a6ec1 → MERGED (ci OK). Final-review note: summary projection duplicated from MonitorLive `presented` (dedupe candidate). Quit during running sweep untested.
- W4b fixes 4e95efc → rebased onto W4a, gate OK → MERGED 0909d1e.
- User approved: install feat/storage build to /Applications/Warden.app, FDA scan, one real deletion of ~/Library/Caches/com.example.storage-fixture only.
- W4-final MERGED 813bc0e (10 goldens, TTTable text-click select fix, tooltip share, ci OK). computer-use not reachable in T3 thread; live checklist in progress/W4-final.md for user/interactive session.
- Installed feat/storage @ 813bc0e to /Applications/Warden.app (Release, Apple Development sig, team 9U2M8A88F2), launched.
- Open: Space key focus (TTTable), double-click group expand unconfirmed, noFDA mock restricts only Desktop, Overview 1100 clips cards (unrelated). Next (awaiting user go): fixes + final whole-feature Codex review.
- W4-final (sonnet) was running in ../telltale-storage-w4f (ws/storage-w4f). Then: final whole-feature Codex review (astra xhigh) → address → ask user re merge to dev.
- W4b done ce77310. Review r1: 1 P1 (selection editable mid-clean) + 3 P2 (toast Show dismiss, confirm breakdown links, own-run leak) → W4b resumed.
- W4a fixes f223f47 → MERGED. Leftover for W4-final: TTSpaceMap tooltip % includes restricted weights (needs per-tile share override).
- W4a review r1: 6 P2 + 2 P3 → W4a resumed (keyboard controller, restricted weights, page states in Cleanup, cancel→retry, derived cache, TTSegmented disabled option, formats, tooltips, noFDA fixture restricted root child). Live checks pending W4-final.
- W4a done d135ab1 (ci OK; renders read). Agent used python/perl for 2 edits (rule breach; diff reviewed by Codex). Orchestrator visual notes: monochrome tiles, inconsistent header subtitle/chip 1100 vs 1280, 2-decimal tile sizes vs 1-decimal strip, no hatch visible, lone "~" breadcrumb. Review storage-w4a-review-r1 running.
- W4c review: 2 P2 + 1 P3 fixed 3c38210 → W4c MERGED. Final-review notes: mock seeding duplicated TelltaleRuntime vs ScreenCatalog.storageModel; summary write-path older-scan check reads file on MainActor.
- W4c T3–T6 44214d4 (ci OK; summary loaded at launch; --mock-storage). User decision: sidebar copy "<bytes> to free" (no ≈) → W4c fixing. Told W4a: Storage header must not show time-range/pause controls.
- W4c scaffold 59c8d7f MERGED. Running (sonnet): W4a ws/storage-w4a, W4b ws/storage-w4b (from 59c8d7f), W4c remaining T3–T6.
- W4 briefs 11b0e14. Orchestrator did prerequisite cf8b93a (StorageModel.seedAccess, public isCheckable/displayBytes). Decisions: Free-up-space link in Disk flyout (DESIGN); dbl-click group=expand, item=Reveal. Order: after W3b merges → W4c first commit (stubs, catalog, StorageFormat) merged → W4a/W4b/W4c parallel → W4-final. Recurring stale CPrivate ModuleCache: rm ModuleCache + CPrivate.build, rebuild twice.
- Rate limit hit (all 3 agents died); resumed W2a final fixes, W3b (had uncommitted Engine/ files), W4 briefs.
- W3b (sonnet) started ws/storage-w3b @ d32c471. Opus writing W4 briefs.
- W2c r1 fixes ddf587f (all 17; ci OK; RemoveFileShim.h hand-declared). r2: P1 2/3/4 resolved; P1-1 Empty Trash bypass + 11 ms/mutation denylist rebuild → redesign (identity set once/run + live path-component check per mutation). Done 7c08799 (1000 auths 184 ms debug). W2c MERGED. Reviews closed.
- W2c done (b40fd15, 5aa783c, rebased 508449b, ci OK). Review storage-w2c-review-r1 (astra xhigh) running. Review r1: 4 P1/11 P2/2 P3 accepted → W2c resumed (fresh denylist check per mutation, per-run cancel, CPrivate removefile shim + MonitorDiskTools→CPrivate dep, no undo adopt, link-aware freed bytes...). Contract: CleanItemOutcome.path: String? (W2c fills for Empty Trash; W3a adds identical hunk).
- W3a batch API ce16baf (2000 events: 42 ms debug / 27 ms release). W3a MERGED. No r2 (sole P1 has break-once test; final review covers).
- W3a r1 fixes c5be4ad (27 tests, ci OK; busyReason/canScan/canClean; CleanItemOutcome.path added). Perf 7.9 s/2000 events (overlay O(n) recompute per mutation) → W3a adding overlay batch API + batched brute-force test.
- W3a done (9cf85d1, 099494c on 508449b; ci OK). Review r1: 1 P1/10 P2 accepted → W3a resumed (scan/clean mutually exclusive + version-bound outcomes; incremental accumulators; deferred reclassify; Empty Trash per-outcome via optional path field → relay to W2c).
- W3c review: 2 P2 fixed d611a24. W3c MERGED into feat/storage.
- W3c done a4d1f93 (ci OK); review storage-w3c-review-r1 (sol medium). W3b must add storageActions to RuntimePipeline. Fixture ids in progress/W3c.md.
- W3 briefs 1a4d603 (StorageCleanMath shared in W3a; decorateStorageActions hook in W3b; scan(root:willUnmount:)). Orchestrator added MonitorRuntimeTests deps 508449b.
- Running (sonnet): W3a ws/storage-w3a, W3c ws/storage-w3c (from 508449b), + W2a, W2c. W3b after W2a–c merged.
- Then: fix verified W1 P1s → merge ws/storage-w1 → feat/storage → worktrees ws/storage-w2{a,b,c,d} → 4 sonnet implementers.
