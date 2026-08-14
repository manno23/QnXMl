# IMPL-IPC — QNX-Native Implementation Spec: IPC, Manager/Client Lifecycle, Failure Management

| Field         | Value                                                                 |
|---------------|-----------------------------------------------------------------------|
| Document ID   | IMPL-IPC                                                              |
| Parent spec   | VWC-SRS-001 (Rev A) — `docs/VWC-SRS-001.md`                           |
| Scope         | VWC-SYS-001..006, VWC-IPC-001..003, 010/020/030/031/032/091,         |
|               | VWC-TXN-001..006, VWC-FLT-001..004                                    |
| Companion     | IMPL-STORE.md (Store + Intent Journal durability; TBD — see §D)       |
| Target        | QNX SDP 8.0, aarch64le, Raspberry Pi 5 (4× A76)                       |
| Verification  | I = Inspection, A = Analysis, D = Demonstration, T = Test             |
| Status        | Research + spec only. No code. Cites local skill files + house code.  |

This document records **QNX-native mapping decisions, test designs, and
hazards** for the IPC/lifecycle/failure slice of VWC-SRS-001. It assumes the
house style already proven on a Pi 5: `QnXMl/lib/region_stubs.c` (the
`__QNXNTO__` MsgSendv/MsgReceive/MsgReply/pulse wrappers) and
`QnXMl/demo/{producer,consumer}.ml` (a working pulse control plane over a
named shm region). Every decision below defers to that house style and to
the project-local QNX skill at `/home/jm/data/qnx/.pi/skills/qnx-os-and-application-design/`.

Citation key (local paths, all read for this doc):
- **SKILL**   = `…/qnx-os-and-application-design/SKILL.md`
- **ARCH**    = `…/qnx-os-and-application-design/references/architecture.md`
- **PTS**     = `…/qnx-os-and-application-design/references/processes-threads-scheduling.md`
- **MC**      = `…/qnx-os-and-application-design/references/multicore.md`
- **MEM**     = `…/qnx-os-and-application-design/references/memory.md`
- **SRS**     = `/home/jm/data/qnx/VWC-OCaml/docs/VWC-SRS-001.md`
- **STUBS**   = `/home/jm/data/qnx/QnXMl/lib/region_stubs.c`
- **DEMO**    = `/home/jm/data/qnx/QnXMl/demo/{producer,consumer,layout}.ml`

---

## 0. Mandatory design preflight (per SKILL "Mandatory design preflight")

```text
SDP release + environment script : QNX SDP 8.0; `. ~/qnx800/qnxsdp-env.sh`
Target CPU, core count, endian   : aarch64le, 4× Cortex-A76 (RPi 5), little-endian
Process vs thread                : Manager = one process; Clients = separate processes
                                   (SYS-001). Commit path = single serialized thread
                                   inside the Manager (SYS-001 rationale).
Scheduling policy + priority     : SCHED_FIFO, priorities 30/31 (Manager dispatch),
                                   ≤63 so unprivileged (no PROCMGR_AID_PRIORITY)
                                   — matches DEMO layout.ml producer_prio=30,
                                   consumer_prio=31.
IPC role                         : Manager = server (one channel, name_attach'd);
                                   Client = client (name_open → coid → MsgSend).
                                   messages vs pulses = both (messages for RPC,
                                   pulses for M→C notifications).
Resource manager?                : NO full pathname resmgr. name_attach for discovery
                                   + dispatch/message_attach for the catalog. See §A.4.
Hardware / DMA / SMMU            : none in this slice (no IRQ, no DMA).
Timing constraints               : commit total order is the real-time invariant;
                                   no hard deadline specified (open item).
Memory                           : shm objects (shm_open, MAP_SHARED); wired by
                                   default in QNX 8.0 (MEM §1, §5: mlockall is a
                                   no-op). No typed memory / MAP_PHYS needed.
```

---

## A. QNX-native mapping decisions

### A.1 Transport skeleton (SYS-001, IPC-001, IPC-002, IPC-003)

**SYS-001 — exactly one Manager, zero or more Clients.** The Manager is one
process owning **one channel** created with `ChannelCreate(_NTO_CHF_DISCONNECT)`
(STUBS `qr_channel_create`, line 177; the flag is already there). Every
Client is a separate process that connects once and reuses its `coid` for all
RPC. `_NTO_CHF_DISCONNECT` is mandatory — it is the kernel hook for FLT-001
(§A.7). [ARCH §3; STUBS line 177]

**IPC-001 — synchronous send/receive/reply.** Every Client-initiated
operation is `MsgSendv`/`MsgReceive`/`MsgReply` over the channel, exactly the
house wrappers `qr_msg_send`/`qr_msg_receive`/`qr_msg_reply[v]` (STUBS
lines 192-265). The Client thread is **SEND-blocked → REPLY-blocked** for the
whole RPC; this is the kernel-enforced backpressure the SRS rationale cites
(SRS IPC-001). **Priority inheritance is automatic and free on QNX
messages** — ARCH §2: *"a blocked sender lends its priority to the receiver,
preventing priority inversion across both messages and mutexes"*; PTS §5:
*"a server receives in priority order and inherits the highest sender's
priority."* This is a **spec strength to call out**: the SRS requires
backpressure; QNX additionally guarantees that a high-priority Client's
commit is serviced at that Client's priority with no inversion, at zero
design cost. **Do not set `_NTO_CHF_FIXED_PRIORITY`** (it would disable this
inheritance — only justified with a documented reason). [ARCH §2, §3; PTS §5]

**IPC-002 — Manager→Client notifications are pulses only.** PULSE_HEAD (090)
and PULSE_FLUSH (091) go out as `MsgSendPulse(coid, -1, code, value)` via
`qr_msg_send_pulse` (STUBS line 277). Pulse payload is `struct _pulse`:
**1 byte `code` + an 8-byte `union sigval`** (ARCH §4). Concretely:
- **PULSE_HEAD**: `code = 90`, `sigval.sival_int = new head_seq`. Advisory —
  the Client MUST re-read the authoritative `head_seq` from the snapshot
  Region via `qr_load_acq` on wakeup (because of pulse compression, §C.1).
- **PULSE_FLUSH**: `code = 91`, `sigval` = requested boundary or 0 (a level
  signal: "seal at next boundary"). The Client Seals at its next allocation
  boundary or replies MSG_ABORT within the configured bound (IPC-091).
- **Codes 90 and 91 are valid**: user pulse codes must lie in
  `_PULSE_CODE_MINAVAIL.._PULSE_CODE_MAXAVAIL`, which DEMO layout.ml pins as
  **0..127**; 90 and 91 fit. So the SRS message IDs double directly as
  on-wire pulse codes — no remapping needed. The pulse `code` byte lives at
  byte offset 4 of `struct _pulse`; DEMO layout.ml's `pulse_code` extractor
  reads it from bits 32..39 of word 0, and the `sigval` is word 1 — reuse
  that extractor verbatim. [ARCH §4; DEMO layout.ml lines 32-44]

**IPC-003 — per-channel receive order = total order.** The kernel guarantees
that a single thread calling `MsgReceive` on one channel dequeues messages in
a **deterministic order** — and that order IS the SRS's "total order of
operations." Critical subtlety from ARCH §2: the channel's **Send queue is
*priority-ordered*, not arrival-ordered** ("Send (priority-ordered pending
senders)"). So the total order is **priority-stratified**: among equal-
priority Clients it reduces to FIFO; a higher-priority Client's commit
serializes ahead of lower-priority commits that are pending. The SRS wording
("per-channel receive order") is satisfied either way — the order is simply
"whatever `MsgReceive` returns." **Design decision:** keep a **single
dispatcher thread** doing `MsgReceive` → process-commit → `MsgReply` → loop,
which makes the total order trivially equal to the dispatch order and
matches SYS-001's "single serializer eliminates operation-log contention."
Do NOT spread commit handling across a worker pool — that would destroy
total order unless re-serialized. Non-commit work (GC sweep, flush timer)
may live on other Manager threads. [ARCH §2; SRS SYS-001 rationale]

### A.2 Discovery and the resource-manager verdict (IPC-010)

**IPC-010 — MSG_ATTACH.** Two QNX options exist for service binding:

1. **Full resource manager**: `resmgr_attach(dpp, attr, "/dev/vwc", ...)` so
   Clients `open("/dev/vwc")` and the framework translates `read/write/
   ioctl/devctl` into `io_*` handlers. [ARCH §5]
2. **Named channel + custom dispatch**: `name_attach()` for discovery +
   `message_attach()` for the custom catalog + a hand-rolled or
   `dispatch_block`/`dispatch_handler` loop. [ARCH §3, §5]

**Verdict: option 2 — `name_attach` + `message_attach`, NOT a pathname
resource manager.** Rationale:
- The SRS message catalog (MSG_ATTACH/ACQUIRE/COMMIT/…) is a **custom,
  session-based, typed-envelope protocol** (SRS §7 table; `lib/ipc/ipc.mli`
  `envelope = { id; seq; payload }`), not POSIX `read`/`write`/`ioctl`.
  Registering `io_read`/`io_write` would imply `cat /dev/vwc` works, which
  is meaningless for a session-RPC service and would invite misuse.
- ARCH §3 DO: *"prefer `name_attach()`/`name_open()` for stable service
  discovery over hard-coded `(pid, chid)`."* `name_attach` gives stable
  discovery with no obligation to implement POSIX I/O semantics.
- ARCH §5 notes the dispatch library's `message_attach(dpp, attr, lo, hi,
  func, handle)` is *exactly* for "servers that have a channel + dispatch
  loop but custom (non-POSIX) message types." This routes our envelope IDs
  to handlers while still giving us, for free: a unified pulse+message
  dispatch loop, multithreaded dispatch support, and combine-message
  handling.
- For POCs and the host test path, the house hand-rolled `MsgReceive` loop
  (DEMO consumer.ml) is sufficient and proven; `message_attach` is the
  production refinement.

**So the binding is:** `ChannelCreate(_NTO_CHF_DISCONNECT)` → `name_attach`
(register a well-known name) → single-threaded `dispatch_block`/
`dispatch_handler` loop (or the hand-rolled equivalent) that switches on
`envelope.id`. The Client side is `name_open` → `coid` → `MsgSendv`. On the
host build, where `qr_channel_create` raises `Failure` (STUBS `#else`), the
test harness substitutes a Unix-domain-socket mock transport that preserves
the same envelope framing. [ARCH §3, §5; STUBS lines 286-291]

### A.3 Region handle passing — the SCM_RIGHTS question (SHM-002, IPC-010/020, RGN-002)

This is the single most portability-sensitive decision in the protocol.
SHM-002 requires *"Region descriptors conveyed to Clients only within IPC
replies (SCM_RIGHTS on Linux; shm handle on QNX)."* The Linux side uses
ancillary-data fd duplication. **QNX has no SCM_RIGHTS analogue over
messages**, because on QNX an fd *is* a connection (`coid`) minted in the
*client's* own fd table by the client's own `ConnectAttach`/`open` — a
server cannot drop a foreign fd into a reply and have the kernel duplicate
it the way `SCM_RIGHTS` does. (Confirms the SRS transport split: Linux =
`SOCK_SEQPACKET + SCM_RIGHTS`; QNX = native MsgSend with no ancillary
channel — SRS §7 header.)

Two QNX-native mechanisms satisfy "shm handle on QNX":

**(B, recommended) Secure shm handle — `shm_create_handle` family.** MEM §2
and §4 list the secure variants: `shm_create_handle()`,
`shm_open_handle()`, `shm_open_handle_pid()`, `mmap_handle()`,
`mmap_handle_pid()` — described as *"anonymous, sealable, revocable objects
without public pathnames"*; MEM §2: `mmap_handle()` *"maps via a
`shm_create_handle()` handle instead of an fd (more secure; the `_pid`
variant verifies the producing PID)."* This is the QNX-native equivalent of
fd-passing:
- Manager: `shm_open(...)` + `ftruncate` + `mmap` (it retains this open fd
  for the Region's whole life — SHM-001, so the backing survives a Client
  unmap, SHM-008), then `shm_create_handle()` → an **opaque handle value**.
- Manager serializes the handle into the MSG_ATTACH_REGION / MSG_ACQUIRE
  reply (this *is* the "shm handle on QNX" of SHM-002).
- Client: `shm_open_handle_pid(handle, manager_pid)` (the `_pid` variant
  verifies the producing PID — MEM §2) → its own local fd → `mmap(MAP_SHARED)`.
- No public pathname; anonymous, revocable (`shm_revoke`), implicitly locked
  if populated via `shm_ctl` (MEM §4). Aligns with HDL-003 generation bumps
  (revocation/re-creation on reclaim) and RES reclamation.

**(A, fallback / host path) Name-based rendezvous.** Manager creates a
named object under `/dev/shmem/<name>`; reply carries the **name string**;
Client `shm_open(name)` → fd → mmap. This is **already proven on the Pi 5**
by DEMO producer.ml (`Region.create ~name`) + consumer.ml
(`Region.attach ~name`) — they rendezvous by the name `"/qnxml_demo"`.
Simplest path; the downside is a public pathname (mitigate with mode 0600,
an unguessable generation-tagged name like `/dev/shmem/vwc-<repo>-r<rid>-g<gen>`,
and Manager-side permission checks). This is also the **host-test path**:
`shm_open` is plain POSIX, so the same code runs under `make host`.

**Decision:** target = mechanism B (`shm_create_handle` family); fallback
and host-test = mechanism A (named rendezvous). **Encapsulate the seam**:
the current `lib/core/region.mli` declares `handle : t -> int` and
`attach : handle:int -> …` — a bare `int`. That is too narrow: a QNX shm
handle is an opaque (possibly multi-word) value, a Linux fd-passed handle
is an `int`, and a host-test handle is a name string. **Refine `Region.handle`
to a `Region_handle.t` variant** (`Fd of int | Qnx_handle of … | Name of
string`) so the wire field labelled "fd" in the SRS catalog (MSG_ATTACH_REGION,
MSG_ACQUIRE, the `standby_fd`) carries the right thing per platform without
touching the catalog. [MEM §2, §4; SRS §1, SHM-001/002, RGN-002; STUBS
`qr_map` lines 60-95; DEMO producer.ml/consumer.ml]

**Bulk data is NOT in any message.** Because both Manager and Client map the
*same* Grant, MSG_COMMIT's payload is only `{OpaqueRef, base_op_seq, meta}`
(SRS §7 row 030); the Manager dereferences the OpaqueRef against its **own**
mapping (region.mli `resolve`) to read the Write Log. No log bytes cross
the wire. This is the house zero-copy philosophy verbatim: STUBS line 166-169
— *"Deltas travel as word-ranges of the region; MsgSendv points its iov
straight at the mapped memory — no serialization, no copy on the OCaml
side."* `MsgSendv`/`MsgReplyv` with iovs *into* mapped region slices is used
for the small control payloads and the COMMITTED reply (`qr_msg_replyv`,
STUBS line 246) — zero copy on both ends, runtime lock released across the
blocking call (STUBS `caml_release_runtime_system`/`acquire`).

### A.4 Transaction processing (TXN-001..006)

**TXN-001 — the 9-step commit order.** Classification (kernel call vs
userspace), in the strict SRS order:

| # | Step                              | Kernel / userspace        | Notes                                                                              |
|---|-----------------------------------|---------------------------|------------------------------------------------------------------------------------|
| 1 | idempotency check                 | userspace                 | Manager-side `(writer_id, writer_op_seq)` → prior-result map (SYS-006, IPC-031).   |
| 2 | handle/generation validation      | userspace                 | `Opref`/`Region.resolve`; gen mismatch → FAULT reply, client re-attaches (FLT-003).|
| 3 | acquire-load of Seal              | userspace (no syscall)    | `qr_load_acq` on the Grant header (STUBS line 137). SHM-006: no syscall for visib. |
| 4 | Intent Journal append + fsync     | **kernel**: write + fsync | TXN-002 record; the first durability point. TXN-003 msync (if SHM-009) precedes.   |
| 5 | log replay + merge against base   | userspace                 | Read Write Log from the Manager's own Grant mapping; CRC per LOG-002/006.          |
| 6 | content-defined re-chunking       | userspace (CPU)           | Superseded ranges only.                                                            |
| 7 | single Store transaction          | **kernel**: commit/fsync  | TXN-004: one SQLite-WAL txn = the second durability point.                         |
| 8 | shared-memory publication         | userspace (no syscall)    | `qr_store_rel` snapshot area + head_seq. TXN-005: only after step 7.               |
| 9 | reply                             | **kernel**: MsgReply(v)   | `qr_msg_reply`/`qr_msg_replyv` (STUBS line 239/246).                               |

Where iov-zero-copy shines: step 9's COMMITTED reply (`MsgReplyv` into the
Region) and any inline-bearing message (MSG_ACQUIRE `paths[]`). The bulk
Write Log never becomes a message (§A.3). **Two real fsync points** exist —
step 4 (Intent Journal) and step 7 (Store txn). TXN-004's "single fsync
point; no multi-file ordering" refers to the *Store side*: chunks, recipes,
trees, commit, view, op-row all commit in one SQLite transaction (one fsync
for that group). The Intent Journal is a *separate, earlier* durable
artifact whose whole purpose is to span the window between "commit started"
and "Store durable" (FLT-002 step 3 replays it). This is the canonical
intent-log-plus-DB-commit pattern, not a contradiction. [SRS TXN-001..005;
STUBS; region.mli]

**TXN-002 — Intent Journal record.** Fixed-size record = `writer_id,
writer_op_seq, OpaqueRef (16 B), base_op_seq, CRC`. **Appended where:** a
flat append-only file on the QNX persistent filesystem (QNX6/fs-qnx6.so on
eMMC/SD), opened `O_RDWR|O_APPEND|O_CREAT`, `write()` the fixed record,
`fsync()`, then proceed to step 5. The SRS calls it a "fixed record
appended" (not a DB row), and the `Open items for Revision B` explicitly
defer "Intent Journal rotation" — both confirm a flat file, not an LMDB/SQLite
table. The Store itself (SQLite/LMDB) is the sibling IMPL-STORE.md concern.
Rotation: when the file crosses a threshold, start a new epoch file; old
fully-replayed files are unlink'd after FLT-002 replay (bounded by the Store
GC, RES-003). **QNX flash fs note:** on QNX6 `fsync()` flushes to media;
verify the target's actual media (eMMC vs SD) semantics on-target (§D).
[SRS TXN-002, §11 open items; IMPL-STORE.md TBD]

**TXN-003 — msync before journal append (when SHM-009 durability enabled).**
For file-backed overlay Grants only: `msync(MS_SYNC)` of the sealed Write
Log dirty ranges completes before step 4. For memfd/default Grants this step
is a no-op (memfd isn't backed by a file msync can flush). Instrumented in
the step-order test (§B). [SRS SHM-009, TXN-003]

**TXN-006 — CONFLICT policy (disjoint slots).** Pure userspace, on the
Manager. Maintain a per-Region index `op_seq → touched-slot-set` (or the
dual `slot → last-touching-op_seq`). For a commit with `base_op_seq < Head`:
gather all ops in `(base_op_seq, Head]`; union their touched slots; intersect
with this commit's touched slots. **Empty intersection → disjoint → proceed.**
**Non-empty → configured policy**: `merge-at-file-granularity` (proceed,
mark affected files for later merge) or `CONFLICT` (reply `Conflict{slots;
head_op_seq}` per IPC-032 — every conflicting slot plus the Head op that
superseded its base). No kernel calls; this is a set operation over the
Manager's in-memory indices. [SRS TXN-006, IPC-032]

### A.5 Failure management (FLT-001..004)

**FLT-001 — Client termination via the QNX disconnect pulse.** This is *the*
QNX answer to Linux pidfd/socket-hangup. The channel is already created with
`_NTO_CHF_DISCONNECT` (STUBS line 177). When a Client process dies, the
kernel tears down all its connections (`ConnectDetach`-equivalent) and, for
each coid that pointed at a `_NTO_CHF_DISCONNECT` channel, delivers a
**`_PULSE_CODE_DISCONNECT` (`-33`)** pulse to that channel with `rcvid == 0`
and the dying connection's `scoid` in the pulse (ARCH §4; DEMO layout.ml
line 37 encodes `-33 land 0xFF`). Handling:
- The Manager's dispatch loop sees `rcvid == 0`, reads `code`; on
  `_PULSE_CODE_DISCONNECT` it maps `scoid → session → Grants` and transitions
  those Grants to `Aborted`, or — *where a durable Seal and Intent record
  already exist* — optionally to `Persisted` per configured policy (FLT-001).
- **Never reply** to this pulse (rcvid == 0 contract, ARCH §2 / SKILL golden
  rule "Check the rcvid").
- Resources: free the session, decrement RES-004 outstanding-Grant counters,
  schedule Grant reclaim (RES-002) once no attached process still publishes
  a sequence needing it.
DEMO consumer.ml already demonstrates the symmetric case (detecting the
*producer's* death via the disconnect pulse, lines "producer disconnected").
[ARCH §2, §4; STUBS line 177; DEMO consumer.ml, layout.ml line 37; SRS FLT-001]

**FLT-002 — restart sequence.** On Manager start (and on restart after
crash): (1) `open` the Store; (2) rebuild the snapshot + operation-log
Regions from the Store; (3) replay Intent Journal records absent from the
Store, discarding any failing LOG-006 CRC validation (torn-tail truncation);
(4) **increment generations of all pre-restart Regions** (HDL-003); only
then (5) `name_attach` and accept sessions. **Generation++ ties directly to
shm object identity (§A.3):** on restart the Manager does NOT reuse stale
shm objects. With mechanism B it creates fresh anonymous handles (old
handles fail to `shm_open_handle_pid` because the producing PID/generation
is gone); with mechanism A it `shm_unlink`s old generation-tagged names and
creates new ones. Either way, any OpaqueRef a surviving Client still holds
fails HDL-002 generation validation → the Client re-attaches (FLT-003). The
Manager's retained open descriptor (SHM-001) is irrelevant post-restart
because the Manager process was replaced; durability comes entirely from
Store + Intent Journal (SYS-004). [SRS FLT-002, HDL-003, SYS-004]

**FLT-003 — Client re-attach on generation failure.** When a Commit reply or
region-table resolution yields a generation mismatch (`Region.resolve` returns
`` `Stale ``): the Client `name_open`s again (fresh coid — the old one may be
dead), sends MSG_ATTACH (new session_id), MSG_ATTACH_REGION for each needed
Region (obtains a fresh shm handle + generation), and **re-issues
unacknowledged commits**. This is safe because commits are idempotent on
`(writer_id, writer_op_seq)` (SYS-006, IPC-031): the new Manager instance
either finds the op already committed in the Store/journal (re-replies the
prior COMMITTED) or executes it fresh. [SRS FLT-003, SYS-006, IPC-031]

**FLT-004 — power-loss resolution.** After FLT-002 restart the state equals
"last durable Store op" plus zero or more fully-replayed intents (those whose
journal record passed CRC). No partial op is observable because: (a) the
Store transaction is atomic (TXN-004 — all-or-nothing); (b) the Intent
Journal record is fixed-size and CRC'd, so a torn final record is discarded
(LOG-006); (c) shared-memory publication (step 8) happens only after Store
durability (step 7, TXN-005), so a crash before step 7 leaves no published
half-state; (d) on restart, generations bump (HDL-003) so no Client can
observe pre-crash shm. [SRS FLT-004, TXN-004/005, LOG-006]

### A.6 Sys-level remainder (SYS-002..006)

- **SYS-002** — only OpaqueRefs cross processes; never a virtual address.
  `lib/core/opref.mli` enforces this: the only cross-process form is
  `to_int64_pair` (the packed 128-bit wire layout). The QNX mapping never
  sends a pointer — `MsgSendv` iovs point into *shared* Region words, and
  OpaqueRefs resolve to local bases per-process. [opref.mli; SRS SYS-002]
- **SYS-003** — single-writer OR immutable-after-publish per Region. The
  Grant is single-writer (the owning Client) during ACTIVE; the snapshot/oplog
  area is Manager-written and immutable-after-publish (SHM-010). QNX shared
  memory + the house acq/rel atomics (`qr_load_acq`/`qr_store_rel`) are the
  sole synchronization — no kernel calls for visibility (SHM-006). [STUBS
  lines 130-162]
- **SYS-004** — Store + Intent Journal are the sole durability authority;
  all shm is reconstructible. Mapped by FLT-002. The Manager holding an open
  fd (SHM-001) is a *liveness* optimization, not a durability claim.
- **SYS-005** — Manager unavailability affects only liveness, not integrity.
  On QNX, a dead Manager's `name_open` fails cleanly (procnto releases the
  name when the owning process dies — ARCH §3 DO/DON'T and failure triage:
  *"name_open fails / stale name → server didn't name_attach, or crashed
  leaving the name"*; verify on-target §D). Committed state lives in the
  Store, untouched. [ARCH §3]
- **SYS-006** — commit idempotency on `(writer_id, writer_op_seq)`. The
  Manager's step-1 lookup (TXN-001) returns the prior COMMITTED without
  re-executing (IPC-031). On QNX this also covers duplicate delivery from a
  Client that crashed mid-RPC and retried. [SRS SYS-006, IPC-031]

---

## B. Test designs

Tests are **host-runnable** (OCaml, `test/`, mock transport where QNX kernel
calls are absent — STUBS `#else` raises `Failure`) and **QNX-target** where
the behavior under test is a kernel guarantee. Each cites its verification
key (I/A/D/T) per SRS §11.

### B.1 IPC-003 — concurrent commits establish a single total order  [T]
- **Host (`test/test_total_order.ml`):** N OCaml *threads* (same address
  space, mock transport = a mutex-serialized in-process Manager) each issue
  K MSG_COMMITs with monotonic `writer_op_seq`. Assert: the Manager assigns
  `op_seq` as a contiguous `1..N*K` with no gaps/dups; each Client's commits
  get strictly-increasing `op_seq`; there exists a serial order consistent
  with every Client's observed order. This validates the *sequencing logic*
  independent of the kernel.
- **Target (`test/qnx/test_total_order_qnx.ml`):** N *processes*
  (`posix_spawn`, PTS §2) at the **same priority** doing real `MsgSendv`.
  Assert the same contiguity/FIFO properties — now exercising the kernel's
  per-channel receive queue. **Extra target assertion (priority-stratified
  order, §A.1):** spawn one Client at priority 31 and the rest at 30; assert
  that under contention the p31 Client's commits are never leap-frogged by a
  p30 commit that arrived later (documents the priority-ordered Send queue).
- **Verification key:** T. **Keys to inspect:** the `op_seq` log, per-Client
  monotonicity, global contiguity. [SRS IPC-003; ARCH §2]

### B.2 IPC-031 — idempotent commit  [T]
- **Host/Target (`test/test_idempotent_commit.ml`):**
  1. Send MSG_COMMIT`(W, K)` → expect `Committed{op_id=A; op_seq=S; …}`;
     record the Store's transaction count `c0` (hook the Store layer).
  2. Send the *same* `(W, K)` again → expect `Committed{op_id=A; op_seq=S}`
     (bit-identical), and Store transaction count still `c0` (no re-exec).
  3. Send `(W, K+1)` → expect a *new* `op_seq=S+1`, count `c0+1`.
- **Crash-retry variant (target):** kill the Manager after Store commit
  (TXN-001 step 7) but *before* MsgReply (step 9); restart (FLT-002);
  Client retries `(W, K)`; assert the restarted Manager replays the journal,
  recognizes `(W,K)` as committed, and re-replies the *same* `Committed`
  without a second Store transaction. Proves SYS-006 + IPC-031 + FLT-002
  jointly. [SRS IPC-031, SYS-006]

### B.3 TXN-001 — step-order instrumentation  [T]
- **Host/Target (`test/test_commit_step_order.ml`):** instrument each of the
  9 steps with `qr_monotonic_ns` (STUBS line 296; CLOCK_MONOTONIC — SKILL
  golden rule "Measure with CLOCK_MONOTONIC"). For one commit, assert the 9
  timestamps are strictly increasing in the SRS order. **Specific
  invariants:** (4 journal fsync) < (7 Store commit) < (8 shm publication) <
  (9 reply); (3 acquire-load Seal) < (4 journal); if SHM-009 enabled,
  (msync) < (4 journal) — TXN-003; (8 publication) never precedes (7 Store)
  — TXN-005.
- **Fault injection:** kill the Manager (a) between steps 4 and 7, (b)
  between 7 and 9. Assert FLT-002 restart resolves to: (a) op absent from
  Store but present in journal → replayed → present; (b) op present in Store
  → idempotent re-reply on Client retry. No partial publication observable
  (FLT-004). [SRS TXN-001/003/005, FLT-002/004]

### B.4 TXN-006 — disjoint vs overlapping slots  [T]
- **Host (`test/test_conflict.ml`, pure-logic; target optional):** seed the
  Manager with op A at Head touching File-Table slots `{0,1,2}`. Then for a
  new commit B with `base_op_seq = A-1` (i.e., base precedes Head):
  - B touches `{3,4}` → disjoint → expect `Committed`.
  - B touches `{1,5}` → overlaps slot 1 → expect `Conflict{slots=[1];
    head_op_seq=A.op_seq}` (IPC-032: *every* conflicting slot + the Head op).
  - B touches `{0,1,2}` → `Conflict{slots=[0;1;2]; head_op_seq=A.op_seq}`.
  - Toggle policy to `merge-at-file-granularity` → the overlapping cases
    return `Committed` with affected files marked for merge (assert the merge
    marker, not a Conflict).
- **Assertions:** slot-set intersection correctness; `head_op_seq` always
  identifies the superseding op; policy switch flips the reply shape.
  [SRS TXN-006, IPC-032]

### B.5 FLT-001 — Client kill matrix  [T]
- **Target (`test/qnx/test_flt001_kill.ml`):** the only meaningful place to
  test disconnect-pulse delivery is on QNX (the host has no
  `_NTO_CHF_DISCONNECT`). Matrix:
  - **K1:** Client attached + acquired a Grant + written, **not committed**;
    `kill -9`. Assert: Manager receives `_PULSE_CODE_DISCONNECT` for that
    scoid, transitions Grant → `Aborted`, frees the session, Store txn count
    unchanged, RES counters decremented.
  - **K2:** Client killed **mid-commit** (after Intent Journal fsync, before
    Store commit) with a durable Seal+Intent present. Assert: per configured
    policy, Grant → `Persisted` (journal replay finishes the op) **or**
    `Aborted` (intent discarded) — test both branches.
  - **K3:** Client killed **after** COMMITTED + unmap (clean). Assert: clean
    session teardown, Grant already `Persisted`, no Store change.
  - **Leak check:** after the full matrix, `pidin` the Manager's
  channel/connection counts; assert they return to the pre-test baseline
  (no connection/channel leak). [SRS FLT-001; ARCH §2, §4]

### B.6 FLT-002 — restart under load  [T]
- **Target (`test/qnx/test_flt002_restart.ml`):** drive continuous commits
  from N Clients; at random points `kill -9` the Manager and `posix_spawn`
  a fresh one. After each restart assert:
  - every op whose Store txn committed is present in the Store (query it);
  - every op whose Intent Journal record fsync'd but whose Store txn did
    **not** commit is now present (replayed) **iff** its journal CRC passed
    (inject a corrupted tail record → assert it's discarded, LOG-006);
  - generations of all pre-restart Regions are incremented (HDL-003): old
    OpaqueRefs fail `Region.resolve` with `` `Stale `` → Clients re-attach
    (FLT-003) and continue;
  - no partial op is observable (FLT-004): the Store + journal resolve to
    "last durable op + fully-replayed intents."
- **Power-fail campaign (FLT-004, key A+T):** on real hardware, cut power
  at random offsets during a commit stream; on next boot run FLT-002 and
  assert the same resolution. On host/dev, *simulate* power-fail by killing
  the Manager and discarding non-fsync'd buffers via the fsync-order fault
  injector (TXN-003/005 test hook). [SRS FLT-002/004, LOG-006, HDL-003]

### B.7 IPC-010/020/030 + handle passing (cross-cutting)  [T]
- **MSG_ATTACH** returns a session_id + Head snapshot Region handle
  (IPC-010); **MSG_ACQUIRE** populates the File Table from the Head current
  at processing time and records it as `base_op_seq` (IPC-020);
  **MSG_COMMIT** replies `Committed` only after TXN-004 durability
  (IPC-030). Test all three through one end-to-end script
  (`test/test_attach_acquire_commit.ml`): attach → acquire → write log →
  seal → commit → assert Store durable **before** the reply is observed
  (inject a crash between Store-commit and reply; the reply must never have
  been delivered for an un-durable op — TXN-005/IPC-030).
- **Handle-passing (SHM-002):** on target, assert the Client can `mmap` the
  Region obtained via mechanism B (`shm_open_handle_pid`) and via mechanism
  A (named `shm_open`) and that writes published by the Manager are visible
  to the Client via `qr_load_acq` (SHM-006) with no syscall. On host, only
  mechanism A is exercised. [SRS IPC-010/020/030, SHM-002/006]

---

## C. QNX-specific hazards

1. **Pulse compression (IPC-002, PULSE_HEAD/PULSE_FLUSH).** ARCH §4:
   *"Identical `(priority, code, value)` pulses are compressed with a count
   — do not rely on one-pulse-per-event counting."* Treat pulses as
   **level** signals: on waking, re-read the authoritative value from shm
   (`qr_load_acq` of `head_seq`) rather than trusting the pulse count. For
   PULSE_HEAD this is desirable (only the latest head matters); for
   PULSE_FLUSH, two merged flushes = one seal, which is correct. **Never**
   use pulse count as an event tally. [ARCH §4]
2. **rcvid contract — never reply to rcvid == 0; always reply to rcvid > 0
   on EVERY path.** ARCH §2 table; SKILL golden rule. The danger is the
   error path: if TXN-001 step 2 (gen validation) fails, the handler must
   still `MsgReply` with `Fault` — a bare `return` leaves the Client
   REPLY-blocked forever. Mitigation: a single reply point per handler
   (functor/finally over the dispatch switch); the house demos already
   pattern-match all three rcvid cases (DEMO consumer.ml, producer.ml).
   [ARCH §2; STUBS `qr_is_pulse`; DEMO]
3. **Receive-buffer sizing + length validation.** Size the receive buffer
   to the largest expected message and check `info.msglen` before trusting
   the payload (SKILL golden rule "Validate every incoming message"; ARCH §2
   DO). The house `qr_msg_receive` returns `(rcvid, nbytes)` and bounds-
   checks the destination range *before* the kernel copies (STUBS lines
   215-238) — keep that pattern; reject oversized/undersized envelopes.
4. **Connection/channel leak.** Client: `ConnectDetach`/`name_close` on
   detach; Manager: `ChannelDestroy` + `name_detach` on shutdown (ARCH §3
   DO). The kernel cleans up a *dead* process's objects, but the Manager
   must free its **per-session** state on the disconnect pulse (FLT-001) —
   the kernel won't run your OCaml finalizers. Assert stable `pidin` counts
   in the kill matrix (§B.5).
5. **name_attach cleanup after crash.** ARCH §3 failure triage warns of
   stale names. On QNX, procnto releases a `name_attach` name when the
   owning process dies (the name is pid-tracked), so a post-crash `name_open`
   should fail cleanly rather than connect to a stale channel — but
   **verify on-target** (§D); if any staleness appears, `name_detach` with
   `NAME_FLAG_DETACH_SAVED_NAME` on startup before re-attaching. [ARCH §3]
6. **`_NTO_CHF_INHERIT_RUNMASK` — server-does-work-on-client-CPU.** MC §2:
   setting it on `ChannelCreate` makes the receiving server thread adopt the
   sender's runmask. The Manager does real work (re-chunking, Store commit)
   on behalf of the Client, so this *could* improve cache locality. Trade-
   off: the server thread **migrates** to the Client's CPU, hurting Manager-
   side determinism (MC §4: *"thread migration, cross-CPU wakeups, and cache
   effects add jitter"*). **Decision: leave OFF by default** (the house demo
   pins Manager-equivalent and Client threads separately, DEMO layout.ml);
   revisit after profiling. If turned on, pin the Manager's non-commit
   threads independently. [MC §2, §4]
7. **Priority ceiling without `PROCMGR_AID_PRIORITY` (≤ 63).** PTS §4:
   unprivileged threads are 1–63; >63 needs the `PROCMGR_AID_PRIORITY`
   ability; the ceiling is raised with `procnto -P`. The house demo keeps
   priorities at 30/31 (DEMO layout.ml lines 50-53) precisely so the
   unprivileged `qnxuser` needs no ability. **Keep the Manager at ≤ 63.**
   Note also PTS §5: privileged boosts from inheritance are *capped* at the
   highest unprivileged priority without the ability — so a Client at 31
   inheriting-up the Manager stays ≤ 63. [PTS §4, §5; DEMO layout.ml]
8. **Disconnect pulse vs COIDDEATH — don't confuse direction.** FLT-001 is
   *Manager detecting Client death* → `_NTO_CHF_DISCONNECT` +
   `_PULSE_CODE_DISCONNECT` (scoid in the pulse). The *reverse* (Client
   detecting Manager death) would be `_NTO_CHF_COIDDEATH` /
   `_PULSE_CODE_COIDDEATH` on the Client's channel — relevant to FLT-003
   re-attach detection, a separate code path. Wiring these backwards is a
   classic bug. [ARCH §4; DEMO layout.ml line 37]
9. **Priority-ordered Send queue (IPC-003).** The total order is priority-
   stratified, not wall-clock FIFO (§A.1). If a future requirement demands
   strict FIFO across mixed priorities, the lever is `_NTO_CHF_FIXED_PRIORITY`
   — but that also disables priority inheritance (net negative). Document
   the stratified-FIFO semantics as the intended behavior. [ARCH §2; PTS §5]
10. **shm object lifetime vs `shm_unlink` timing.** SHM-001 requires the
    Manager to retain an open descriptor for the Region's whole life; SHM-008
    lets a Client unmap a sealed Grant before the data is reclaimed. On QNX,
    a shm object survives until **both** unlinked and last-fd-closed. With
    mechanism A (named), `shm_unlink` must happen only when *no* Client still
    maps it (RES-002 gating) — premature unlink + a new Client `shm_open`
    could race. With mechanism B (handle), revocation is explicit
    (`shm_revoke`). Tie unlink/revoke to HDL-003 generation++. [MEM §4;
    SRS SHM-001/008, RES-002, HDL-003]

---

## D. Open items — needs on-target verification

1. **shm handle marshalling (mechanism B).** MEM §2/§4 describe
   `shm_create_handle`/`shm_open_handle[_pid]`/`mmap_handle[_pid]` as the
   secure anonymous path, but the skill does not give the **byte-level layout
   or size** of the handle value to serialize into a MsgReply. Confirm
   against the installed C Library Reference (`shm_create_handle`) and prove
   end-to-end on the Pi 5: Manager creates → serializes handle into reply →
   Client `shm_open_handle_pid(handle, mgr_pid)` → `mmap` → visible writes.
   Until proven, ship mechanism A (named rendezvous, already demo-proven).
2. **name_attach staleness after crash.** Verify on-target that `name_open`
   after a Manager `kill -9` fails cleanly (no stale channel) — or define
   the `NAME_FLAG_DETACH_SAVED_NAME` re-attach dance. [ARCH §3]
3. **Priority-stratified total order (IPC-003).** Confirm the kernel's
   Send-queue ordering under mixed-priority Clients matches §A.1 (high-prio
   dequeued first; equal-prio FIFO). The skill states the rule; the test
   (§B.1 target) must confirm it on the installed procnto.
4. **Intent Journal `fsync` semantics on the target media.** Confirm QNX6
   `fsync()` on eMMC (and SD, if used) actually flushes to media within the
   latency budget the 9-step pipeline assumes. Media-dependent; not
   inferrable from the skill.
5. **Pulse pool sizing under burst.** ARCH §4: `MsgSendPulse` returns
   `EAGAIN` if the pulse pool is exhausted. Under a Head-storm (many
   PULSE_HEAD) or many simultaneous PULSE_FLUSH, size `ChannelCreatePulsePool`
   (ARCH §3) on the *Client's* receive channel so notifications aren't
   dropped. Confirm empirically on-target.
6. **`_NTO_CHF_INHERIT_RUNMASK` effect on Manager jitter.** Decide on/off
   after profiling commit latency with the Manager pinned vs runmask-
   inheriting (hazard §C.6).
7. **Does the Manager ever need priority > 63?** If real-time deadlines
   require it, grant `PROCMGR_AID_PRIORITY` (and document); else stay ≤ 63
   (hazard §C.7). Open until a deadline is specified.
8. **IMPL-STORE.md (sibling) not yet written.** TXN-002/004 and FLT-002
   step 3 depend on Store + Intent Journal details (SQLite-WAL vs LMDB,
   single-fsync semantics, GC closure for RES-003). This spec assumes a flat
   fsync'd Intent Journal file + a SQLite-WAL Store per the TRACE.md module
   map; reconcile when IMPL-STORE.md lands.
9. **CONFLICT policy selection matrix** (SRS §11 open items) — the
   `merge-at-file-granularity` vs `CONFLICT` decision per workload is
   unspecified; TXN-006 (§A.4) implements both behind config but the default
   is TBD.
