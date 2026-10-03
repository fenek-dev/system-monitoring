# Storage & Cleanup Spikes (M1 Max, macOS 26.5 / Darwin 25.5, SDK 26.5, Swift 6.3.3)

Measured on macOS 26.5 only. Deployment target is macOS 14.0 (`project.yml:5`, `MonitorCore/Package.swift:19`). SDK headers carry **no** availability annotations for any of the flags/attrs below (`O_RESOLVE_BENEATH`, `O_NOFOLLOW_ANY`, `RENAME_*`, `REMOVEFILE_RECURSIVE_SLIM`, `ATTR_CMNEXT_*`, `IOPOL_*` are bare `#define`/enum), so behavior on 14.x is **inferred, not verified**. Scratch code: `/tmp/storage-spikes/*.c|swift` (not committed). Spike numbers refer to the brief.

## 1. O_RESOLVE_BENEATH / O_NOFOLLOW_ANY
- Status: ✅ (26.5); 14.x unverified
- Headers: `sys/fcntl.h:128 O_RESOLVE_BENEATH 0x1000` (comment: "same value as FMARK"), `:158 O_NOFOLLOW_ANY 0x20000000`, `:185 AT_RESOLVE_BENEATH`. No availability annotation.
- `openat(dirfd, p, O_RDONLY|O_RESOLVE_BENEATH)` results:
  - `sub/f` OK; `sub/../sub/f` (inner `..` staying inside) OK; inner relative symlink `inl -> sub/f` OK
  - `../outside/s`, `sub/../../outside/s` -> `Capabilities insufficient` (ENOTCAPABLE)
  - absolute symlink escape `abs/s` (abs -> /tmp/.../outside), relative symlink escape `sub/rel/s`, absolute path argument -> ENOTCAPABLE
  - control without flag: `abs/s` opens fine (escape works) — proves the flag is what blocks it.
- `O_NOFOLLOW_ANY`: rejects a symlink at *any* component (final `inl` and mid-path `abs/s` -> ELOOP "Too many levels of symbolic links"); plain `O_NOFOLLOW` only guards the final component (`abs/s` mid-symlink opened OK).
- Recommendation: use `O_RESOLVE_BENEATH` (+ `O_NOFOLLOW_ANY` when no symlink should be traversed) for every delete/trash/stat-under-root fd open. Risk on 14.x: a kernel that doesn't know the bit may silently ignore it (value collides with FMARK) -> runtime self-test at launch (open `../` relative to a temp dir, must fail with ENOTCAPABLE) and fall back to fd-per-component walk with `O_NOFOLLOW|O_DIRECTORY` + `fstat` dev/ino checks if the probe opens. Needs a 14.x VM/machine to confirm (user action).

## 2. removefile: RECURSIVE_SLIM, removefileat, callbacks
- Status: ✅ with a gotcha
- `removefile.h:33 REMOVEFILE_RECURSIVE_SLIM (1<<11)` ("DFS, reduce memory"); `removefileat(int fd, path, state, flags)` at `:71`; `removefile_cancel(state)` at `:73`. No availability annotation.
- `removefile("rm1", st, RECURSIVE|RECURSIVE_SLIM)` -> rc=0, tree gone, symlink inside pointing outside was removed as a link and target left intact (`outside_intact=1`). `removefileat(dirfd,"rm2",st,RECURSIVE)` rc=0, tree gone.
- Callback API (enum `REMOVEFILE_STATE_*`): `CONFIRM_CALLBACK=1`, `ERROR_CALLBACK=3`, `ERRNO=5` (read-only), `STATUS_CALLBACK=6`. (There is no `..._ERROR_CB` name.) Return `REMOVEFILE_PROCEED/SKIP/STOP`.
- **Gotcha: SLIM + confirm/status callback -> rc=-1 errno=EINVAL, nothing removed** (`SLIM + confirm cb rc=-1 errno=22 confirm_calls=0`; same for status cb + SLIM). Plain RECURSIVE + callbacks works (status cb fired 4482x in 150 ms on a 30k-file tree).
- Error callback works with both modes: on locked dir (mode 555) cb fired per failing path with `REMOVEFILE_STATE_ERRNO` = 13 (EACCES) / 66 (ENOTEMPTY); returning SKIP continued, final `rc=0` for RECURSIVE (rc=0 errno=66 for SLIM, so check errno via state, not the return). Without an error cb the first failure aborts the whole removal (`rc=-1 errno=13`, siblings left).
- Cancel: `removefile_cancel(state)` from another thread @150 ms -> `rc=-1 errno=89 (ECANCELED)`, 30000 -> ~25-26k files left, for both RECURSIVE and SLIM (SLIM without callbacks). Cancelling from inside a confirm cb (RECURSIVE) also ECANCELED. Cancel before the call is a no-op (state reset). Confirm-cb `REMOVEFILE_STOP` returned rc=0 errno stale — do not use for cancel; use `removefile_cancel`.
- Recommendation: SLIM + `removefile_cancel` + ERROR_CALLBACK only (no confirm/status cb). Progress = own accounting (bytes known from scan) or poll. If progress needed per-item, use non-SLIM with status cb. Gate SLIM on a launch probe (EINVAL on a flag-unknown kernel) with fallback to plain RECURSIVE. Always pass dirfd-relative via `removefileat` after the beneath-open check.

## 3. ATTR_CMNEXT_PRIVATESIZE
- Status: ✅ obtainable via `getattrlistbulk`
- Bulk: `attrlist.forkattr = ATTR_CMNEXT_PRIVATESIZE (0x8)` + `FSOPT_ATTR_CMN_EXTENDED` (0x20) alongside `ATTR_CMN_RETURNED_ATTRS`; returned mask has `forkattr=00000008`, value (off_t) is packed after file attrs. Without `FSOPT_ATTR_CMN_EXTENDED` the forkattr bit is not returned. Also works per-file via `getattrlist(path, ..., FSOPT_ATTR_CMN_EXTENDED)`.
- 8 MiB random file, `cp -c` clone (APFS):

```
orig   alloc=8388608 datalen=8388608 private=0      (both share all extents)
clone  alloc=8388608 datalen=8388608 private=0
plain  alloc=4096    datalen=3       private=4096   (non-cloned file: private == alloc)
```
- After overwriting 2 MiB of the clone (`dd conv=notrunc`): `clone private=2097152` (< alloc 8388608). A third clone (`sub/inner`) still shared the rest, so deleting orig left clone private=2 MiB — private size reflects extents referenced by exactly one file; it is a per-file lower bound of reclaimable bytes, not additive across a clone set.
- Dirs: returned in the bulk entry with forkattr bit set and `private=0` (not recursive); dir entries also omit file attrs (alloc/datalen). Dir totals must be summed by the walker.
- Recommendation: request PRIVATESIZE in the same bulk call (no extra syscalls) for candidate files/items shown in the UI; size lists by `alloc`, "reclaimable" by sum(private) with a caveat that clone sets freed together may reclaim more. Check `forkattr` bit in the returned mask before reading (graceful on older OS). Unverified on 14.x (attr defined since 10.15 SDK era, likely fine).

## 4. Finder "Put Back" for FileManager.trashItem
- Status: ✅ (strong indirect evidence); Put Back UI itself not driven (needs Finder GUI)
- `trashItem(at:resultingItemURL:)` on file and dir -> landed in `~/.Trash/<name>`, resulting URL returned.
- No put-back xattr on the trashed file (`xattr -l`: only `com.apple.TextEncoding`, `com.apple.macl`, `com.apple.provenance`). Put-back info lives in `~/.Trash/.DS_Store` (ptbL/ptbN records), which this terminal cannot read (`Operation not permitted`, TCC: no Full Disk Access; `ls ~/.Trash` also denied).
- Control experiment via `stat -f %Sm` on `~/.Trash/.DS_Store` (size 16388 both times):
  - before: `02:08:47`; after plain `mv` into `~/.Trash`: `02:08:47` (unchanged)
  - after `trashItem` of a file + dir: `02:09:10` (updated at the call)
  So `trashItem` makes the system write the Put Back entry; plain rename does not.
- Cleaned up: all items created (3 files/dirs x2 runs + control) removed from `~/.Trash`. `.DS_Store` may retain stale entries for them (harmless).
- How to verify fully (user action): run the spike (or app) with FDA, `strings -e b ~/.Trash/.DS_Store | grep <name>` should show the original path entries; or trash an item then in Finder open Trash -> right-click -> "Put Back" is enabled; repeat with a plain-`mv` item (control: disabled/absent).
- Recommendation: use `FileManager.trashItem` (not rename into `.Trash`) and persist the returned `resultingItemURL` for an in-app undo (rename back, with `RENAME_EXCL`). Don't claim Finder Put Back in UI until the user-action check passes.

## 5. proc_pidinfo pass cost
- Status: ✅
- Per sweep over all pids (proc_listpids -> per pid: PROC_PIDT_SHORTBSDINFO, proc_pidpath, PROC_PIDVNODEPATHINFO (cwd), PROC_PIDLISTFDS, then PROC_PIDFDVNODEPATHINFO per vnode fd):
  - runs: 37.3 (cold first), 19.3, 18.7, 17.4, 19.1 ms -> **median 19.1 ms** (1226 pids, 890 owned, ~10.8k fds, 5588 vnode fds)
- Results counts (stable across runs): listfds / cwd ok=890, EPERM=332 (other-user/root pids), other=2-3 (exited mid-sweep/ESRCH); per-vnode-fd path info ok=5517, EPERM=71 (inside owned procs, e.g. hardened/entitled ones), other=0; `proc_pidpath` ok=1213 (works even for other users' pids, EPERM=0), other=11-12 (kernel/zombie pids).
- Recommendation: open-file/cwd "in use" pass is cheap (~20 ms) and can run just before each delete confirmation and on scan end. Treat the 332 EPERM pids as "unknown holders" (root-owned: inaccessible without privilege) — the check is advisory, not a guarantee; still handle EBUSY/EPERM at delete time. Re-run ESRCH tolerance (pid exits mid-sweep).

## 6. getattrlistbulk walker
- Status: ✅
- Layout varies per entry: with `FSOPT_PACK_INVAL_ATTRS`, returned-attrs mask for dir entries has `fileattr=00000000` (no alloc/datalen) while file entries have `fileattr=00000204` (ALLOCSIZE|DATALENGTH). Over the whole home dir: dirs_without_file_attrs = 861759 of 861759 dirs; files_with_file_attrs = 5384975 of 5384975 files. Bit-for-bit consistent, so parser must read fields by the per-entry returned mask (with/without `PACK_INVAL_ATTRS` the same layout was seen for the tested attrs). `commonattr` returned `80000009` (RETURNED_ATTRS|NAME|OBJTYPE).
- Walk of `$HOME` (6.25M entries: 5.38M files, 0.86M dirs; opened with `O_NOFOLLOW`, 256 KiB buffer/thread, dir queue + worker threads, read-only; "warm" = repeat run, not purged):
  - 8 threads: 99k, 128k, 137k, 122k entries/s (45-63 s; first run 63 s was partially cold)
  - 1 thread: 26k entries/s (239 s) -> 8 threads ~4.7-5.2x
  - 143 EPERM/EACCES dir opens (TCC-protected dirs: Library subfolders etc.), ~150 total errors
- Caveat: summed ALLOCSIZE = 1196 GB for $HOME is larger than real usage would suggest — it double counts hardlinks/clones and includes non-purgeable sparse/VM images; use `st_dev/ino`/CLONEID-LINKID dedupe and PRIVATESIZE for reclaim estimates. Cold-scan timing: **user action** (needs `sudo purge`, not run).
- Recommendation: 8 workers is a good default (~125k entries/s warm); full-home scan ~50 s so scan must be incremental/cancelable and UI must not block on it. Request only NAME|OBJTYPE|ALLOCSIZE(+PRIVATESIZE) in the bulk call; skip TCC dirs gracefully (count them for a "needs Full Disk Access" hint).

## 7. renameatx_np with RENAME_EXCL | RENAME_NOFOLLOW_ANY
- Status: ✅ (26.5); `renameatx_np` annotated `__OSX_AVAILABLE(10.12)` (`sys/stdio.h:53`). `RENAME_NOFOLLOW_ANY 0x10` and `RENAME_RESOLVE_BENEATH 0x20` are bare defines (`sys/stdio.h:39-40`) -> 14.x unverified.
- Results:
  - to free name: OK; to existing name: `EEXIST` (no overwrite)
  - dest path through a symlinked dir (`linkparent/y`): with `RENAME_EXCL|NOFOLLOW_ANY` -> ELOOP, nothing moved; with `RENAME_EXCL` only -> OK, file landed outside via symlink (`real/y exists=1`)
  - source path through symlinked dir with NOFOLLOW_ANY -> ELOOP
  - adding `RENAME_RESOLVE_BENEATH` with a `../` dest -> ENOTCAPABLE
- Recommendation: use for restore/undo moves (`RENAME_EXCL|RENAME_NOFOLLOW_ANY`, + `RENAME_RESOLVE_BENEATH` where a root dirfd is held) to avoid clobbering and symlink redirection. Same silent-ignore risk on older kernels as #1 (unknown flags normally return EINVAL for rename, which is safe -> map to fallback to `RENAME_EXCL` + lstat checks).

## 8. setiopolicy_np dataless materialization
- Status: ✅
- `setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES /*3*/, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF /*1*/)` compiles and returns `rc=0`; `getiopolicy_np(...)` read back `1`.
- Recommendation: set on every scanner/worker thread (policy is per-thread, so set inside each pthread/GCD worker, and reset to ORIG/DEFAULT if threads are pooled and reused) so reading iCloud/dataless items never triggers downloads. Behavioral check that a dataless file is not materialized needs an iCloud Drive "Optimize Storage" file (not exercised; user action).

## User actions / not verified
- Cold-scan timing (needs `sudo purge`) — skipped per brief.
- All of the above on macOS 14.x (deployment target) — flags unannotated in headers; need a 14.x machine/VM.
- Put Back in Finder GUI and `.DS_Store` ptbL contents (needs Full Disk Access for the terminal).
- Dataless no-materialize behavior with a real iCloud placeholder.
