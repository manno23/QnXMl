# IMPL-STORE — Durable Store + Intent Journal + Reclamation (QNX-native)

Implementation specification for **VWC-SYS-004/005/006, VWC-TXN-001..006,
VWC-FLT-001..004, VWC-RES-001..004** of `VWC-SRS-001` (Rev A).

Scope: the Store (`lib/ipc/store`), the Intent Journal (`lib/ipc/journal`),
and the OCaml↔LMDB C shim (`lib/vwc_stubs.c`, extending the
`foreign_stubs` block already declared in `lib/dune`). The Store module is
**greenfield** — `lib/ipc` currently contains only `ipc.mli`; `store` and
`journal` are declared in `lib/dune` (modules line) but not yet written.

Spec deviation under review: VWC-SRS-001 §1 defines the Store as
"SQLite-backed" and VWC-TXN-004 says "single Store (**SQLite WAL**)
transaction". The project owner has asked to evaluate **LMDB** instead. This
document recommends LMDB and shows the TXN-004 mapping (LMDB has no WAL;
its atomic single write-transaction + metapage commit is the substitute).

All QNX facts below were verified against the installed **QNX SDP 8.0**
target sysroot at `…/qnx800/target/qnx/usr/include` (aarch64le), and by
**empirically cross-compiling and linking** the vendored LMDB with
`qcc -Vgcc_ntoaarch64le`.

---

## 0. Preflight — verified QNX/LMDB portability facts (the headline)

These were checked by reading the installed QNX headers and by actually
building. They are the load-bearing facts for every later section.

### LMDB cross-compiles for QNX aarch64le with ZERO patches

The vendored source is the official `LMDB/lmdb` repo, **`mdb.master3`**
branch (the in-development pre-2.0 line; `lmdb.h` still reports
`MDB_VERSION_MAJOR 0 / MINOR 9`, copyright "2015-2021"), at commit
`567292b` ("ITS#10551 lmdb: fix mdb_page_split nodesize calculation"):
`vendor/lmdb/libraries/liblmdb/`.

`mdb.c` selects its platform backend by `#ifdef` on `__linux` / `__APPLE__`
/ `BSD` / `__FreeBSD_kernel__` / `__ANDROID__` / `__HAIKU__`
(`mdb.c:165-201`). **QNX/Neutrino matches none of these**, so it falls
through to the POSIX default:
- `MDB_USE_POSIX_MUTEX` (`mdb.c:224`, the `#else` of the `!_WIN32` block).
- `MDB_USE_ROBUST` = 1 (`mdb.c:362-364`: not Android, not ancient glibc;
  QNX defines neither `__ANDROID__` nor `__GLIBC__`).
- `MDB_FDATASYNC` defaults to `fdatasync` (`mdb.c:577-578`).
- `MDB_DSYNC` = `O_DSYNC` (`mdb.c:566-567`).
- `MDB_MSYNC` = `msync` (`mdb.c:582`).
- `MDB_USE_HASH` is **not** set (only POSIX_SEM/SYSV_SEM set it).

Every libc symbol that default path requires is **present in QNX 8.0**:

| LMDB needs (`nm -u` on built `mdb.o`) | QNX header / symbol | Location |
|---|---|---|
| `fdatasync` | declared | `target/qnx/usr/include/unistd.h:485` |
| `fsync` | declared | `unistd.h:486` |
| `msync` + `MS_SYNC`/`MS_ASYNC`/`MS_INVALIDATE` | declared | `sys/mman.h:250`, `MS_SYNC=0x2`@144, `MS_ASYNC=0x1`@143 |
| `O_DSYNC`, `O_SYNC` | defined | `fcntl.h:86`, `fcntl.h:88` |
| `mmap`/`munmap`/`mprotect` | declared | `sys/mman.h` |
| `fcntl` + `F_SETLK`/`F_RDLCK`/`F_WRLCK`/`F_GETLK` + `struct flock` | declared | `fcntl.h:143,185,186,218` |
| `posix_memalign` | declared | `malloc.h:59` (also `aligned_alloc`@54) |
| `pread`/`pwrite`/`writev` | declared | `unistd.h` / `sys/uio.h` |
| Robust mutexes: `EOWNERDEAD`/`ENOTRECOVERABLE` | defined | `errno.h:114,157` |
| `PTHREAD_MUTEX_ROBUST`, `pthread_mutex_consistent`, `pthread_mutexattr_setrobust`, `pthread_mutexattr_setpshared` | declared | `pthread.h:329,379,390` |

Empirical build (the authoritative evidence):

```
qcc -Vgcc_ntoaarch64le -O2 -Wall -Wextra -Wno-unused-parameter -c mdb.c  -o mdb.o   # exit 0, zero warnings
qcc -Vgcc_ntoaarch64le -O2                          -c midl.c -o midl.o            # exit 0
qcc -Vgcc_ntoaarch64le -O2 -I…/liblmdb linktest.c mdb.o midl.o -o linktest         # links, exit 0
```

The linked test's `NEEDED` list is **only `libc.so.6` and `libgcc_s.so.1`**
— no `-lpthread`, no `-lrt`, no `-lsocket`. (`-lrt` is a no-op on Neutrino
since rt lives in libc; sockets need `-lsocket` but LMDB does not use them.
See `QnXMl/docs/CROSS.md` "Config results worth knowing".)

**Verdict: LMDB mdb.master3 is source-portable to QNX 8.0 aarch64le with no
patches and no extra link libraries.** `posix_memalign` being in
`<malloc.h>` rather than `<stdlib.h>` on QNX is harmless — mdb.c compiles
clean even under `-Wall -Wextra` (qcc's `<stdlib.h>` transitively exposes
it), verified above.

### CRC32C (VWC-LOG-002) is one ARM instruction — but needs `-march=…+crc`

`region_stubs.c` in the sibling `QnXMl` project has atomic/memcpy/mmap
stubs but **no CRC32C**; `VWC-OCaml/lib` has no stubs file yet. The
Pi 5's BCM2712 (Cortex-A76, ARMv8.2-A) **does** implement the CRC32/CRC32C
instructions, and the ACLE header exists at
`…/host/linux/x86_64/usr/lib/gcc/aarch64-unknown-nto-qnx8.0.0/12.2.0/include/arm_acle.h`.

BUT `__ARM_FEATURE_CRC32` is **not** defined by qcc's default aarch64
march, and the assembler rejects the instruction out of the box:

```
qcc -Vgcc_ntoaarch64le … inline-asm crc32cx …   → Error: selected processor does not support `crc32cx w1,w1,x2'
qcc -Vgcc_ntoaarch64le -march=armv8-a+crc …      → exit 0; objdump shows `crc32cx w1,w1,x2`  ✓
qcc -Vgcc_ntoaarch64le -march=armv8-a+crc … __crc32cd … → exit 0; emits `crc32cx` ✓
```

**Action (section E hazard + stub):** add `crc32c_*` to the new
`vwc_stubs.c`, guarded by `#if defined(__aarch64__) && defined(__ARM_FEATURE_CRC32)`
(emitting `__crc32cd`/inline `crc32cx`), with a portable Sarwate/table
fallback for the host build, and compile the target object with
`-march=armv8-a+crc` (set via `c_library_flags`/`-Xcc` in the dune
`foreign_stubs` stanza). CRC32C over the Write-Log header+payload (LOG-002)
and the Intent record (TXN-002) both use it.

---

## A. Store choice verdict

**Recommendation: LMDB** (vendored `mdb.master3`, cross-compiled with
`qcc`), hosted on a **QNX6 ("Power-Safe") filesystem** partition for
production and on **`devf-ram`** for POC. The Intent Journal stays a
**separate fixed-record raw file** (section C). SQLite is a viable but
inferior fallback — it ships preinstalled, but its durability model is
worse fit for the immutable+reversible op log.

### Rationale table

| Axis | (a) **LMDB** ✅ | (b) SQLite | (c) Append-only log + fsync (Intent-Journal-only) | (d) QNX etfs |
|---|---|---|---|---|
| **Mutability model** | MVCC B+tree; append-only *keys* give an immutable op log; overwrites are opt-in | Row-oriented SQL; immutability is a schema discipline, not a property | Pure append-only byte stream; immutable by construction | **Not applicable** (see below) |
| **MVCC / reversibility** | Native: read-only txn = consistent snapshot of every DBI at begin time; "revert to seq N" = read-only txn + cursor ≤ N | Needs `BEGIN` snapshot isolation or a history table — heavier | Reversibility = read prefix up to N; trivial, but no random/indexed access | n/a |
| **Cross-compile cost on QNX 8.0** | **Zero patches, zero extra libs** (verified §0); one TU (`mdb.c`+`midl.c`) into `vwc_stubs` | **Shipped preinstalled**: `target/qnx/aarch64le/usr/lib/libsqlite3.{so,a}` (+ `-noicu`); `-lsqlite3 -dsqlite3` | Trivial: a `write()`+`fsync()` loop in `vwc_stubs.c`; no third party | **Not present in this SDP/BSP** (`find … -iname '*etfs*'` returns only `getfs*` libc helpers; no `fs-etfs*` binary for aarch64le) |
| **Durability primitives** | `mdb_txn_commit` → atomic metapage `msync(MS_SYNC)` + data `fdatasync` (default); `MDB_NOSYNC`/`MDB_NOMETASYNC`/`MDB_WRITEMAP`/`MDB_MAPASYNC` to tune (`lmdb.h:354-362`) | WAL (`PRAGMA journal_mode=WAL`) + `fsync`; one fsync per commit, plus checkpoint fsyncs | `pwrite`+`fsync`/`O_DSYNC`; CRC-checked fixed records (LOG-006 torn tail) | Transactional/power-safe at the FS layer, but raw-NAND oriented |
| **QNX file layout (host the data + lock files)** | `data.mdb` + `lock.mdb` on a **qnx6 partition** (e.g. `/data/vwc/`); **`lock.mdb` must be on a real fs** (POSIX `MDB_USE_POSIX_MUTEX` stores a robust `pthread_mutex_t` in the mmap'd lockfile — `/dev/shmem` is not a full fs and will not do, see `target-operations.md`) | Single db file on qnx6; same constraint | One journal file on qnx6 (or `devf-ram` for POC) | n/a |
| **Fit to "immutable + reversible op log"** | Exact: append-only composite keys + MVCC snapshots | Round peg, square hole | Exact for the log, but you lose indexed access to chunks/recipes/trees → you'd rebuild a KV anyway | n/a |

### Why not the alternatives

- **SQLite (the spec's pick).** It *is* on the target
  (`libsqlite3.so.1`), so there is no porting cost, and `PRAGMA
  journal_mode=WAL` + `synchronous=FULL` satisfies TXN-004. The cost is
  conceptual: SQLite gives you a row store, not a MVCC snapshot tree.
  "Revert to seq N" and RES-003 GC-over-a-closure both become hand-rolled
  SQL + a history table, and you forfeit LMDB's zero-malloc, page-mapped
  read path that maps cleanly onto the shared-memory snapshot Regions
  (SHM-010). We keep SQLite as the **documented fallback** if LMDB's
  `mdb.master3` branch proves unstable (it is a development branch; see
  Uncertainties).
- **Intent-Journal-only (append-only log + fsync, no KV).** Cheapest and
  fully durable for the *log itself*, but VWC-SRS-001 is content-addressed
  (chunks/recipes/trees/views/commits are first-class, RES-003 walks a
  closure). A log without an index forces O(n) scans for every
  SYS-004 reconstruct and every IPC-031 idempotency probe. You would end
  up writing a poor man's LMDB. Recommended only as a degenerate POC tier.
- **QNX etfs.** Not an option for this target: there is no `fs-etfs`
  driver in the SDP 8.0 aarch64le BSP. ETFS targets raw NAND; the Pi 5
  boots from SD/eMMC **block** media, for which the power-safe filesystem
  is **QNX6** (`fs-qnx6.so`, `mkqnx6fs`, `chkqnx6fs` —
  `target/qnx/aarch64le/lib/dll/fs-qnx6.so`). The transactional/durable
  property the task associated with "etfs" is delivered by **qnx6**
  instead (see §E).

### File-layout decision

| Tier | Where `data.mdb`/`lock.mdb`/journal live | Why |
|---|---|---|
| **Production** | A dedicated **qnx6 partition** mounted at e.g. `/data` (writable, persistent, power-safe COW) | qnx6 is copy-on-write and "never overwrites live data … the new view becomes live only when all updates are safely written" (`com.qnx.doc.neutrino.sys_arch/topic/fsys_QNX6_filesystem.html`) — it reinforces LMDB's own durability. `lock.mdb` needs a real fs for the robust pthread mutex (§E). |
| **POC / host test** | `devf-ram` ("Simulate flash filesystem using RAM memory", `target/qnx/aarch64le/sbin/devf-ram`) on the target; an ordinary tmpdir on the host | `devf-ram` gives a real resource-manager fs in RAM without touching SD, so POC3 can run power-fail drills (`kill -9`) cheaply. On the host (x86_64) LMDB builds with gcc and uses `/tmp`. |

**The Store must NOT live on the IFS.** The IFS is mounted read-only at
`/proc/boot` and "is not a general persistent writable store"
(`qnx-project-development/references/target-operations.md`). `/dev/shmem`
is also disqualified for the Store: it is in-memory, non-persistent, and
"not a fully featured substitute for production `/tmp`" (e.g. `mkdir` is
not supported there) — and LMDB's `lock.mdb` needs directory operations.

---

## B. Immutable + reversible op-log design (how LMDB delivers SYS-006 + reversibility)

The two properties come from **two different LMDB mechanisms** and must not
be conflated:

- **Immutability** is a *keying discipline*, not an LMDB feature. We never
  overwrite; every operation is a new `(writer_id, writer_op_seq)` key.
  LMDB gives us the atomic, checksummed, crash-safe place to put it.
- **Reversibility** *is* an LMDB feature: a read-only transaction is a
  consistent MVCC snapshot of the entire environment as of `mdb_txn_begin`.
  "Revert to seq N" = read-only txn + seek the op-log cursor at the largest
  key ≤ N, then walk reachable view/commit/tree/recipe/chunk pointers.

### DBI (named databases) and key/value schema

Open one LMDB environment with `mdb_env_set_maxdbs(N)`; inside the first
txn, `mdb_dbi_open` each named DBI once. All DBIs share one env so a single
write txn (TXN-004) atomically updates all of them.

| DBI | Key (binary) | Value | Flags | Writes |
|---|---|---|---|---|
| `oplog` | `u32 writer_id ‖ u32 writer_op_seq` (8 B, big-endian for natural cursor order; `writer_op_seq` from HDL-001) | **operation row**: `op_seq, base_op_seq, seal_log_end_offset, commit_ptr, view_ptr, ts_ns, flags, crc32c` | `MDB_CREATE` ; put with `MDB_APPEND` (keys strictly increasing per writer) | append-only; **never overwrite** |
| `chunks` | content hash (the chunk's own digest, content-defined per TXN-001 step 6) | raw chunk bytes | `MDB_CREATE` | put; same hash → same bytes ⇒ idempotent (skip if exists) |
| `recipes` | recipe hash | recipe body (ordered list of chunk hashes / offsets) | `MDB_CREATE` | put (content-addressed) |
| `trees` | tree-root / node hash | tree node | `MDB_CREATE` | put (content-addressed) |
| `commits` | `u32 op_seq ‖ u32 writer_id` (or commit hash) | commit object (manifest of recipes/trees touched, parent commit ptr) | `MDB_CREATE` | append-only |
| `views` | `u32 head_seq` | published snapshot pointer = the Head (SHM-010) as of this op | `MDB_CREATE` | append-only; the "current view" is the max key |

**Immutability / idempotency (SYS-006, IPC-031):** step (1) of TXN-001
(idempotency check) is `mdb_get(oplog, (writer_id,writer_op_seq))`. If the
key exists, the Manager **replies the stored COMMITTED result without
re-executing** (IPC-031) — the 8-byte composite key makes the probe a
single B+tree lookup. Because we use `MDB_APPEND` and never delete live
oplog rows, a duplicate MSG_COMMIT can never mutate state. (Content DBIs
are content-addressed, so re-putting identical bytes is a no-op.)

**Reversibility (MVCC read):** a reader (reconstruct-on-restart, a
read-only client view, or a "revert to seq N" operation) does
`mdb_txn_begin(env, NULL, MDB_RDONLY, &txn)` then `mdb_cursor_get(oplog,
..., MDB_SET_RANGE)` at key `(writer_id, N+1)` and steps backward; the
`view_ptr`/`commit_ptr` of the row at ≤ N gives the as-of-N Head. All
DBIs are seen at the same snapshot, so the closure is internally
consistent. No write, no copy.

**GC (RES-003):** mark the retention closure from the configured retention
roots (live `views` + a sliding window of recent `commits`/`oplog` rows).
Sweep = `mdb_del` every `chunks`/`recipes`/`trees` row whose hash is
unreachable, **in bounded batches** (one write txn per batch, e.g.
≤1000 deletes, to keep the B+tree freelist churn bounded and the writer
blocked for bounded time). LMDB's freelist reclaims the freed pages on the
*next* commit after no reader pins them; set
`mdb_env_set_maxreaders()` to size the reader table (RES-001/RES-002
publish the oldest readable seq, which gates reclaim exactly as the spec
requires — only reclaim a Region/op when *every* attached reader's
published seq exceeds it).

### TXN-004 mapping — one op = one LMDB write transaction

VWC-TXN-004 ("single Store (SQLite WAL) transaction containing chunks,
recipes, trees, commit, view, and operation row") maps 1:1 to **one
`mdb_txn_begin(MDB_NOTLS)` write txn** that `mdb_put`s into all six DBIs,
then a single `mdb_txn_commit()`. LMDB has no WAL and no "multi-file";
the atomic metapage commit *is* the all-or-nothing boundary FLT-004 needs.

### fsync / sync-flag policy (TXN-004, IPC-030, TXN-005)

IPC-030/TXN-005 require the COMMITTED reply to issue **only after** the
Store transaction is durable. Therefore:

- **Store env: default flags, no `MDB_NOSYNC`.** Default LMDB calls
  `fdatasync(env->me_fd)` (QNX-declared, `unistd.h:485`) and
  `msync(MS_SYNC)` on the metapage (`mdb.c:4907`/`:3123`) on every commit
  ⇒ durable before `mdb_txn_commit` returns ⇒ durable before reply. This
  is the **production** setting and the only one that literally satisfies
  TXN-005.
- **POC may use `MDB_NOMETASYNC`** (`lmdb.h:358`) — still fsyncs data, only
  skips the separate metapage `msync`. Given qnx6 is power-safe COW (§E),
  the residual crash window (meta page not yet flushed) collapses to "the
  last commit's metadata" and is acceptable for POC3 speed. **Do NOT use
  `MDB_NOSYNC`** even for POC if you intend FLT-004 to mean anything.
- **`MDB_WRITEMAP`** (`lmdb.h:360`): enable for write throughput (writes
  go straight into the mmap, one copy instead of `pwrite`+read-back). The
  downside is stray-pointer corruption risk into the map; mitigated here
  because the OCaml layer never holds a raw pointer into the LMDB map —
  all access goes through `mdb_get/put` in `vwc_stubs.c`. Enable in POC
  once FLT-004 passes; leave off for the first bring-up.
- **`MDB_MAPASYNC`** (`MS_ASYNC` instead of `MS_SYNC`): **disabled** —
  it weakens durability below the TXN-005 bar (reply-before-durable).
- **`MDB_NOTLS`** (`lmdb.h:364`): enable so read-only transactions are not
  pinned to a thread (the Manager's reader pool and the reconstruct path
  cross threads). Required for the snapshot reader design above.
- **`MDB_NOLOCK`** (`lmdb.h:366`): **off** — we rely on LMDB's robust
  POSIX mutex (`pthread_mutex_consistent`, `EOWNERDEAD`@`errno.h:114`) for
  inter-process safety if a second Manager is ever started, and for the
  reader table.

---

## C. Intent Journal position

**Position (recommended): LMDB's own transactional durability *replaces*
the separate Intent Journal for committed state; the journal is retained
but its job is narrowed to crash-recovery *ordering* and *idempotency* for
ops that crashed in the window between TXN-001 step (4) and step (7).**

Concretely, map the TXN-001 nine steps onto two distinct durability
points:

| TXN-001 step | What becomes durable | Mechanism |
|---|---|---|
| (4) Intent Journal append + fsync | the *intent* (writer_id, writer_op_seq, OpaqueRef, base_op_seq) + a CRC | **separate fixed-record file**, `pwrite`+`fsync` (`O_DSYNC` open, `fcntl.h:86`) — exactly as TXN-002 specifies |
| (3) msync of sealed Write-Log ranges (SHM-007/TXN-003, before step 4) | the sealed Write-Log bytes (file-backed overlay Grant, SHM-009) | `msync(MS_SYNC)`, `sys/mman.h:250` |
| (7) single Store transaction | chunks/recipes/trees/commit/view/oplog row | **one LMDB write txn** commit (TXN-004) |

**Why the journal is NOT folded into the LMDB write txn.** TXN-001 *orders*
step (4) before step (7). If the intent were just another `mdb_put` in the
Store txn, it would commit *with* the data at step (7), losing the early
durability at step (4). Keeping the journal as a **separate file with its
own fsync** preserves that ordering and gives FLT-002 a deterministic,
CRC-checked (LOG-006 torn-tail) replay sequence for ops whose intent was
fsync'd but whose Store commit never finished. On restart (FLT-002):

1. open LMDB env (`mdb_env_open`),
2. rebuild snapshot/oplog Regions from the Store (SYS-004),
3. scan the Intent Journal in seq order; for each record **absent from
   `oplog`**, replay TXN-001 steps (5)–(7) against the msync'd Write-Log
   bytes (still on the file-backed overlay, SHM-009) — discarding any
   record whose CRC fails (LOG-006),
4. increment generations (HDL-003), then accept sessions.

**Why the journal is still arguably *redundant* (the honest counter).**
Because LMDB commits are atomic and the client is reply-blocked until step
(9), an op that crashed before step (7) was never acknowledged; the client
will retry, the step-(1) `mdb_get` finds nothing, and the op re-executes
idempotently. So for *correctness* alone you could drop the journal and
rely on client retry + LMDB. The journal earns its keep on **liveness and
determinism**, not correctness: it lets FLT-002 *complete* in-flight ops
without a client round-trip, preserves the Manager-defined total order
(IPC-003) across restart, and gives IPC-031 a cheap pre-Store idempotency
probe. **Recommendation: keep it (separate file) for the spec-faithful
design; for a minimal POC tier it is the first thing you may stub out.**

**Layout:** the journal file lives on the **same qnx6 partition** as
`data.mdb` (e.g. `/data/vwc/intents.log`) so one physical medium serves
both; preallocate/seek to a fixed size and rotate per the Rev B open item
("Intent Journal rotation", VWC-SRS-001 §11). Fixed 64 B records (writer_id
u32, writer_op_seq u32, OpaqueRef 16 B, base_op_seq u32, CRC32C u32,
padding) — matches TXN-002 exactly.

---

## D. Test designs

Host tests build LMDB with **gcc** (the same `mdb.c`/`midl.c` on glibc)
and exercise the OCaml Store module through `vwc_stubs.c`; target tests
rebuild LMDB with **qcc** and additionally assert QNX-specific flush
behavior. CRC32C uses the software fallback on x86_64 host, the `crc32cx`
instruction on aarch64 target.

| ID | What it proves | Host test (gcc) | Target-only addition (qcc, QNX 8.0) |
|---|---|---|---|
| **TXN-004** | one Store txn per op; all six DBIs atomic | In one `mdb_txn`: put oplog+chunks+recipes+trees+commit+view; commit; open a read-only txn and assert all six are visible together; abort a second op mid-txn and assert none of its partial writes are visible. | — (LMDB atomicity is host/target-identical) |
| **SYS-004** | all shm reconstructible from Store + journal | Write N ops through the Manager; drop all Regions; reopen env, walk `oplog` + `views`, rebuild the Head snapshot Region, byte-compare to the pre-drop snapshot. | additionally assert reopen after `devf-ram` unmount/remount retains bytes |
| **SYS-006 / IPC-031** | duplicate commit is a no-op | Issue MSG_COMMIT(writer=W, seq=S) twice; assert the second returns the stored COMMITTED (same `op_id`/`op_seq`), `mdb_stat` shows one oplog row, chunk content DBIs were not re-written (compare `mdb_stat` page counts). | — |
| **FLT-002** | restart replay ordering/idempotency | Pre-seed the Intent Journal with 3 records where #2 is *not* in `oplog`; restart the Manager; assert #2 is replayed and now present, #1/#3 are skipped (already committed), and a corrupt- CRC #4 is discarded (LOG-006). | — |
| **FLT-004** | power-fail resolves to last-durable + full intents | Loop: between each `mdb_txn_commit` and the simulated reply, `kill -9` the process at a randomized step (via a step-hook in TXN-001); reopen env on restart; assert (a) `oplog` contains exactly the commits whose `mdb_txn_commit` returned, (b) the Intent Journal contains those + the in-flight one, (c) no partial/torn oplog row is observable (LMDB metapage atomicity). Run ≥200 iterations. | **the critical QNX addition**: run on qnx6 with default sync AND with `MDB_NOMETASYNC`, and also do a *real* power-cut (or `shutdown -f`/reset) mid-commit; assert the qnx6 COW guarantee holds — the on-medium `data.mdb` is never torn. Also assert `msync(MS_SYNC)` latency is bounded enough for the commit path (measure with `CLOCK_MONOTONIC`, never `CLOCK_REALTIME`). |
| **RES-003** | GC retains the closure, deletes only outside it | Build a graph: views V0..V3 reachable, plus orphan chunks not referenced by any view; run GC with retention root = {V3}; assert orphans are deleted (via `mdb_stat` page-count drop after the freelist is reclaimed on next commit) and the V0..V3 closure is intact (read-back equals pre-GC). Assert batch bound (≤K deletes per write txn). | — |

**Where the host test approximates:** LMDB's MVCC and B+tree behavior are
identical host vs target (same source), so atomicity/idempotency/GC tests
are faithful on the host. The host test does **not** exercise QNX
filesystem flush semantics — `msync`/`fdatasync` on Linux ext4/tmpfs behave
differently from qnx6, and `devf-ram`/real-SD power-cut behavior can only
be proven on the Pi 5 target. FLT-004's "no partial operation observable"
under real power loss is a **target-only** assertion (the spec marks it
Verify: A + T; the Analysis half is LMDB's documented atomicity, the Test
half must run on qnx6 hardware).

---

## E. QNX-specific hazards

1. **`lock.mdb` requires a real filesystem.** `MDB_USE_POSIX_MUTEX` stores
   a robust `pthread_mutex_t` (`pthread_mutexattr_setpshared` +
   `pthread_mutexattr_setrobust`) in the mmap'd lockfile. `/dev/shmem` is
   not a full fs (`mkdir` unsupported; non-persistent) and the IFS is
   read-only — neither can host it. → Store + lock must be on a **qnx6
   partition** (`/data`). (`target-operations.md`, `bsp-and-images.md`.)
2. **IFS is read-only at runtime.** `/proc/boot` cannot hold `data.mdb`;
   never write the Store path into the IFS expecting it to be writable
   (`target-operations.md`: "the IFS … is not a general persistent writable
   store").
3. **`msync` vs `fsync` semantics on QNX.** QNX `msync` (`sys/mman.h:250`)
   supports `MS_SYNC` (0x2, return when flushed), `MS_ASYNC` (0x1), and
   the QNX extensions `MS_SYNC_FULL` (0x08000000, "Full sync — Flush to
   physical medium") and `MS_INVALIDATE_LOCKED`. LMDB uses `MS_SYNC`
   (`mdb.c:4907`), which flushes to storage. On qnx6 the COW property
   makes `MS_SYNC` sufficient; `MS_SYNC_FULL` is available as
   belt-and-suspenders if a belt-and-suspenders medium barrier is ever
   needed, but LMDB does not currently call for it. (`mmap` of a regular
   qnx6 file with `MAP_SHARED` is the normal path and is what LMDB uses.)
4. **`O_DSYNC`/`fdatasync` are present** (`fcntl.h:86`, `unistd.h:485`),
   so the Intent Journal's `open(O_DSYNC)`+`fsync` and LMDB's
   `fdatasync` both work unmodified — unlike some older QNX docs that
   imply `fdatasync` is missing, **QNX 8.0 declares it** (verified).
5. **File size limits / `mdb_env_set_mapsize`.** LMDB's mmap is a fixed
   virtual reservation set at `mdb_env_open`; on QNX all memory is wired
   (`memory.md`: "all memory is wired — backed by physical RAM … no
   swap/disk paging"), so an oversized mapsize consumes address space but
   not RAM until written. Size the map to the partition's capacity, not
   the RAM, but keep it sane — QNX has no overcommit. Re-grow via the
   documented `mdb_env_set_mapsize`-while-no-readers path.
6. **CRC32C needs `-march=armv8-a+crc`** (§0). If you compile `vwc_stubs.c`
   with the default march, the assembler rejects `crc32cx` and the build
   fails. Wire the flag into the dune `foreign_stubs` stanza (e.g.
   `(flags (:standard -Xcc -march=armv8-a+crc))` for the target context
   only). The host build must take the software-CRC branch.
7. **`mlockall` is a no-op in QNX 8.0** (`memory.md`): all process memory
   is already wired. Do not rely on it for the Store buffers; LMDB's own
   page cache is in the mmap and is wired by virtue of being mapped.
8. **`-lrt` not needed, `-lsocket` not needed for LMDB** (verified: NEEDED
   list is `libc.so.6`, `libgcc_s.so.1` only). The OCaml side already
   learned this for the cross toolchain (`CROSS.md`).
9. **Robust-mutex recovery on Manager crash.** If the Manager dies holding
   the write mutex, the next opener gets `EOWNERDEAD` (`errno.h:114`) and
   LMDB calls `pthread_mutex_consistent` (`pthread.h:379`) to recover —
   this is exactly SYS-005 ("Manager unavailability shall affect only
   liveness … never integrity"). Verify on target with a kill-mid-write
   test (part of FLT-001).

---

## F. Open items / dependencies

- **Parent design `VWC-SDD-001` (`shm-snapshot-cow-spec.md`)** is
  referenced by VWC-SRS-001 §0 but is **not present** in
  `VWC-OCaml/docs/` (only `CROSS.md`, `TRACE.md`, `VWC-SRS-001.md`). The
  Store schema above is inferred from the SRS; reconcile against the SDD
  when it lands.
- **Rev B numeric bounds** (VWC-SRS-001 §11): mapsize, Intent Journal
  rotation size, GC batch bound `K`, retention-root window — all TBD.
- **`mdb.master3` is a development branch.** It builds clean today
  (commit `567292b`) but is not a tagged release; pin the commit in
  `vendor/lmdb` and re-run the §0 build check on any bump. SQLite
  remains the fallback.
- **OCaml binding shape.** `lib/dune` already declares
  `(foreign_stubs (language c) (names vwc_stubs))`; the shim will mirror
  `QnXMl/lib/region_stubs.c`'s style (thin `CAMLprim` wrappers, release
  runtime lock around blocking `mdb_txn_commit`). Add `mdb.o`+`midl.o` as
  extra objects via `(extra_objects mdb.o midl.o)` or a packaged
  `liblmdb.a`; compile them with `-fPIC -march=armv8-a+crc` for the qnx
  context and plain `-fPIC` for host.
