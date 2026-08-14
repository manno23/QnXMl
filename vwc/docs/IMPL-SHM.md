# IMPL-SHM — QNX-Native Implementation Specification
## Shared-Memory Architecture & Grant/Region Layer of VWC-SRS-001

| Field        | Value                                                        |
|--------------|--------------------------------------------------------------|
| Document ID  | IMPL-SHM                                                     |
| Scope        | VWC-SYS-001..006, VWC-SHM-001..010, VWC-HDL-001..004, VWC-RGN-001..008 |
| Parent spec  | `docs/VWC-SRS-001.md` (Rev A)                                |
| Trace matrix | `docs/TRACE.md`                                              |
| Target       | QNX SDP 8.0, AArch64 (Raspberry Pi 5)                        |
| Status       | Rev A (draft) — research + spec; no code                     |

This document replaces every Linux-ism in the parent spec (`memfd_create`,
`SCM_RIGHTS`, `eventfd` doorbells) with the best QNX 8.0 API, and designs the
test matrix that proves the mapping. It is written against the **established
house pattern** in `QnXMl/lib/region.ml` + `lib/region_stubs.c`: one
preallocated, page-touched `Bigarray` of `int64` words over a `MAP_SHARED` shm
object, with `__atomic` acquire/release fences and `MsgSendv`/`MsgReplyv` iovs
pointing straight into the slab. The recommendations here extend, not replace,
that pattern.

### Citation key

- **SKILL** = `qnx-os-and-application-design` skill, e.g. `SKILL/memory.md §4`.
- **CLib** = QNX SDP 8.0 C Library Reference, by function name (URL given inline).
- **Prog** = QNX OS Programmer's Guide, *Working with Memory* chapter.
- **SRS** = `docs/VWC-SRS-001.md` requirement IDs.
- **STUBS** = `QnXMl/lib/region_stubs.c`; **REG** = `QnXMl/lib/region.ml`.

---

## A. QNX-Native Mapping Decisions

### A.0 Guiding facts (verified, not assumed)

1. **A QNX file descriptor is a per-process connection ID (`coid`), not a
   portable integer.** `open()`/`name_open()` "yield an fd that *is* a coid"
   (SKILL/architecture.md §3). An fd integer sent in a message to another
   process is meaningless there. **`SCM_RIGHTS`-style fd passing does not
   exist on QNX.** This single fact determines SHM-002.
2. **`mlockall()`/`mlock()` are no-ops in QNX 8.0** — "all process memory is
   already wired" (SKILL/memory.md §5; CLib `mlockall`: "the pages … are
   memory-resident … for the entire duration of the process, so this function
   does nothing"). Keep calls for portability; never rely on them for
   behaviour.
3. **`shm_create_handle(fd, pid, &handle, …)` returns a single-use,
   process-bound, serialisable handle** for an existing shm object — "provides
   a means for one process to provide another with access to a shared memory
   object without having to share a path" (CLib `shm_create_handle`).
4. **`mprotect()` changes protection on a mapping in the *calling* address
   space only** — there is no remote `mprotect` (CLib `mprotect`; SRS SHM-005).
5. **`msync()` writes "modified data to permanent storage locations, **if
   any**"** (CLib `msync`). A pure shm object lives in `/dev/shmem` (RAM) with
   no backing file, so there is nothing to flush to disk; msync on it is, at
   most, a data-cache barrier.

These five facts collapse the design space below.

---

### VWC-SYS-001 — exactly one Manager + N Clients

**Decision.** Manager and each Client are **separate processes** (one Manager
process per repository instance; zero or more Client processes). The Manager
is a named QNX service. Two acceptable shapes, in increasing order of
"idiomatic":

- **(a) `name_attach()`/`name_open()`** (SKILL/architecture.md §3) — stable
  service discovery under a well-known name (e.g. `dev/vwc/<repo>`), no
  hard-coded `(pid, chid)`.
- **(b) Resource manager** (`resmgr_attach`, SKILL/architecture.md §5) — only
  if Clients are expected to reach the Manager through POSIX `open()`/`devctl()`
  or if permission checks must live in the connect phase.

Recommend **(a)** for Rev A: the message catalog (SRS §7) is bespoke and the
iov-into-slab data path (STUBS `qr_msg_send`) is not a POSIX I/O shape.
Resource-manager framing is deferred to the security hardening pass.

**Why one process = one serializer.** A single Manager thread services the
receive channel in FIFO order; that order *is* the total operation order
(SRS IPC-003). QNX guarantees this: `MsgReceive` on one channel returns one
message at a time, and priority inheritance makes a blocked high-priority
client lend its priority to the Manager (SKILL/architecture.md §2).

### VWC-SYS-002 / SHM-004 — OpaqueRef & region-relative offsets (no raw addrs)

**Decision.** `OpaqueRef` (HDL-001) is a **pure 128-bit value** with no OS
calls — it is never dereferenced as a pointer. All intra-Region references are
**word offsets from the region base**, with offset `0` ≡ null. The existing
`Region.slice`/`Arena` machinery already addresses everything by integer
offset into a `words` Bigarray (REG `slice`; `Arena.get t i f`), so this is the
house pattern verbatim. Resolve → `(region table[region_id].base + offset)`;
no virtual address ever crosses a process boundary.

### VWC-SYS-003 — single-writer *or* immutable-after-publish

**Decision.** Enforced as a **protocol invariant, not by memory protection.**
QNX `shm_ctl(SEAL)` exists but "a sealed object is not write-protected —
anyone who has write access can [still] write" (CLib `shm_ctl`), so hardware
sealing does *not* give immutability. We rely on: (1) exactly one writer per
Grant (the owning Client for the Write Log; the Manager for the
snapshot/oplog), and (2) a single release-store Seal (LOG-005) that makes a
Grant immutable-after-publish. The *only* cross-process primitive is the
release/acquire pair (SHM-006).

### VWC-SYS-004 / SHM-007 — durability ≠ visibility, and msync's real job

**Decision.** Durability authority is the **Store + Intent Journal only**
(`ipc/store`, `ipc/journal`). Shared memory is volatile RAM. Per CLib `msync`,
modified pages are written "to permanent storage locations, **if any**"; a
pure shm object has *none*, so:

- **memfd/shm-backed Grants (the common case):** `msync` is a no-op-ish cache
  barrier. **Do not treat it as durability.** SHM-007's "msync before journal
  append" degenerates to a `__sync_synchronize`-strength fence; real
  durability is the Intent Journal `fsync` (TXN-002/003) and the single Store
  `fsync` (TXN-004).
- **file-backed overlay Grants (SHM-009, opt-in):** here `msync(MS_SYNC)` *is*
  meaningful — it pushes dirty file-mapped pages to the backing file. Use
  `MS_SYNC` (blocks until complete) on the dirty `[0, log_end)` range before
  the Intent Journal append. Do **not** set `MAP_NOSYNCFILE` on these
  mappings (that flag opts *out* of file sync — wrong direction).

`mlockall` is kept for portability but is a confirmed no-op (§A.0.2).

### VWC-SYS-005 / VWC-SYS-006 — manager death ≠ corruption; idempotent commit

**Decision.** Because every Region is reconstructible from Store+Journal
(SYS-004) and the Manager retains the only mutable-authority state, a Manager
crash loses only in-flight, un-`fsync`'d work. Idempotency key
`(writer_id, writer_op_seq)` lives in the Store, not in shm, so it survives
crash/retry (IPC-031 re-replies the prior `COMMITTED`). On restart the Manager
**increments all Region generations** (FLT-002.4, HDL-003), which forces every
Client through HDL-002's stale-generation check → re-attach (FLT-003).

---

### SHM-001 — kernel shm object, Manager retains the fd

**Decision: `shm_open()` + `ftruncate()`, Manager holds the fd for the Region's
whole lifetime.** Mark it revocable with `shm_ctl(fd, SHMCTL_REVOCABLE, …)` at
creation so HDL-002/FLT-001 have a hard-revoke lever.

**Why `shm_open` and not the alternatives:**

| Option | Verdict |
|---|---|
| `shm_open` + `ftruncate` + `mmap(MAP_SHARED)` | **Chosen.** Canonical "fastest IPC" path (SKILL/memory.md §4). Manager-owned fd is exactly the "Manager retains an open descriptor" of SRS SHM-001, which keeps physical frames alive independent of client mappings (the precondition for SHM-008). Matches the existing `qr_map` stub. |
| `shm_create_handle` / `mmap_handle` | Used for **conveyance** (SHM-002), not creation. A handle is minted *from* an `shm_open` fd; it does not itself create an object. |
| `posix_typed_mem_open` | **Rejected** for logical Regions. Typed memory is for *named physical pools* (DMA buffers, below-4G, contiguous). Our Regions are ordinary SYSRAM shared objects; typed memory brings physical-address concerns (SKILL/memory.md §3) we do not want. |
| `MAP_PHYS|MAP_ANON` anonymous | **Rejected.** That is the DMA-buffer pattern (contiguous physical). We need a *named/revocable object* so multiple clients map the same backing store. |

**Manager-held lifetime = SHM-008's enabling invariant.** The Manager never
`close()`s a Region fd until the Region is RECLAIMED. Clients may `munmap`
freely; the object (and the Client's committed data) outlives any single
client mapping. `shm_unlink()` is called only at final reclamation, and is
distinct from unmap (see §C).

### SHM-002 — descriptor conveyed in an IPC reply (NOT fd passing)

**Decision: mint a `shm_handle_t` and serialize its bytes into the `MsgReply`
payload; the Client maps with `mmap_handle()` (or `shm_open_handle()`→`mmap`).**

The complete end-to-end flow:

```
Manager                                                 Client
-------                                                 ------
fd = shm_open("/vwc/region_NN", O_RDWR|O_CREAT, 0600);
ftruncate(fd, len);
shm_ctl(fd, SHMCTL_REVOCABLE, ...);           /* enable later revoke */
... fill grant header/filetable ... in the object ...

/* on MSG_ACQUIRE: */
shm_create_handle(fd, client_pid, &h,           /* reply is being built */
                  oflag, SHM_CREATE_HANDLE_OPT_NOFD);
MsgReplyv(rcvid, EOK, iov[] = { grant_descriptor_fields,
                                 serialized(h) });  ──►   recv reply
                                                          map = mmap_handle(NULL, len,
                                                              PROT_READ|PROT_WRITE,
                                                              MAP_SHARED, h, 0);
                                                          /* h is single-use; consumed */
```

**Justification (this is the crux the task calls out):**

1. **fd passing does not work on QNX.** An fd is a per-process `coid`
   (SKILL/architecture.md §3: "A connection maps directly onto a file
   descriptor … an fd that *is* a coid"). You cannot put an int fd in a reply
   and have it mean anything in the receiver. There is no `SCM_RIGHTS`.
2. **The skill's named idiom is the secure handle family.** SKILL/memory.md §4:
   "Secure variants: `shm_create_handle()`, `shm_open_handle()`,
   `shm_open_handle_pid()`, `mmap_handle()`/`mmap_handle_pid()` … anonymous,
   sealable, revocable objects without public pathnames."
3. **The handle is purpose-built for exactly this** — CLib `shm_create_handle`:
   "returns a unique single-use handle … can be used only once, and only by
   the process specified by `pid`." So it rides inside a `MsgReplyv` iov as
   plain bytes, and the kernel enforces the (object, recipient) binding.
4. **`SHM_CREATE_HANDLE_OPT_NOFD`** prevents the recipient from converting the
   handle into a long-lived fd — so the Manager can later `shm_revoke()`
   access (CLib `shm_create_handle`, `shm_revoke`). Pair this with the
   `SHMCTL_REVOCABLE` set in SHM-001.
5. **`shm_open_handle_pid(h, creator_pid)`** lets the Client verify the handle
   really came from the Manager (anti-spoof) — cheap defense-in-depth.

**Reply shape.** The Grant descriptor (RGN-002 fields) and the handle bytes
travel as one `MsgReplyv` iov array; the Client validates lengths before
trusting either (SKILL/architecture.md §2 "validate every incoming message").
The existing `qr_msg_replyv` stub already replies with region-word iovs;
extending it to append a fixed handle struct is a one-iov addition.

**Open sub-decision (Rev B):** the exact byte size/layout of `shm_handle_t`
must be confirmed from the installed `<sys/mman.h>` on target (the docs describe
it opaquely). Until then the stub treats it as a fixed opaque buffer whose size
is `sizeof(shm_handle_t)`, copied verbatim — never field-by-field.

### SHM-003 / SHM-004 — MAP_SHARED at unspecified base; relative offsets

**Decision.** Clients `mmap(NULL, len, PROT_READ|PROT_WRITE, MAP_SHARED, …)` —
**`addr` is always NULL; never `MAP_FIXED`.** The kernel chooses a base per
process (ASLR). All references are region-relative word offsets (SYS-002).

**Important departure from the current house pattern.** `region.ml`'s `create`
carries an `?addr` parameter whose docstring says "nonzero → MAP_FIXED so every
process sees identical placement." **VWC-SRS-001 forbids exactly this** (SHM-003:
"shall make no assumption of address equality across processes"). The spec
*retires* the fixed-address mode:

- MAP_FIXED requires the `PROCMGR_AID_MAP_FIXED` ability (SKILL/memory.md §2;
  CLib `mmap`), which an unprivileged Client must not hold.
- Identical placement was only ever a convenience so that word-indices could be
  used as cross-process pointers; the spec replaces that with OpaqueRef
  offsets (SYS-002/SHM-004), which are base-independent.

So in the VWC build, `addr` is hard-wired to `0n` (the current default) and the
fixed-address code path is deleted. The anonymous single-process mappings used
by the host test suite are unaffected (they already pass `addr=0n`).

### SHM-005 — guard-page arming, by the mapping process only

**Decision.** The trailing guard page (RGN-001) is armed **by the Client** with
`mprotect(base + guard_off, page, PROT_NONE)` immediately after it maps the
Grant. This is per-address-space by definition (SRS SHM-005; CLib `mprotect`:
"change the access protections on any [mapping in the] calling process's
address space"). No ability is needed for `PROT_NONE` (only `PROT_EXEC` needs
`PROCMGR_AID_PROT_WRITE_AND_EXEC` — CLib `mprotect`, and we never request
`PROT_EXEC`).

**Complementary hardening (optional, Rev B):** `shm_create_subrange_handle()`
(CLib index, sibling of `shm_create_handle`) lets the Manager mint a handle to
*just* the Grant's usable span, excluding the guard page from the Client's
view entirely — so even a buggy Client cannot write the guard region, because
it never maps it. Two layers: subrange handle (range control at mint time) +
`mprotect PROT_NONE` (per-page control at map time). The spec requires the
latter; the former is recommended.

### SHM-006 — release-store / acquire-load publication (house pattern)

**Decision.** Visibility is established **solely** by
`__atomic_store_n(p, v, __ATOMIC_RELEASE)` on the writer and
`__atomic_load_n(p, __ATOMIC_ACQUIRE)` on the reader — exactly the `qr_store_rel`
/ `qr_load_acq` stubs (STUBS). **Confirmed correct on Neutrino/AArch64:** gcc's
`__atomic` builtins lower to `STLR` (release-store) and `LDAR` (acquire-load),
which are the architectural acquire/release barriers; QNX SMP maintains cache
coherency for normal cacheable memory (SKILL/multicore.md §4), so an
acquire-load on core B observes a release-store from core A once the store is
globally visible. No syscall is involved — satisfying "no syscall shall be
required for visibility" (SRS SHM-006). `qr_fetch_add` (`__ATOMIC_ACQ_REL`) is
available for the allocation cursor.

**Caveat (false sharing).** The Manager-owned watermark slot and any
Client-owned cursor that are hit on every allocation must sit on **separate
cache lines** (SKILL/multicore.md §4: "keep per-CPU or per-thread hot data on
separate cache lines"). RGN-001's header layout must pad the watermark word to
its own line (the existing `Vclock` module already does 64-byte padding for the
same reason — `vclock.ml` "pads each per-peer counter onto its own 64-byte
cache line").

### SHM-007 — msync ordering (durability) — see SYS-004

Covered in §SYS-004. Net rule: for **shm-backed** Grants, msync is a fence
only; for **file-backed** overlay Grants (SHM-009), `msync(MS_SYNC)` on the
dirty range is the real pre-journal durability step (TXN-003). In neither case
does `mlockall` contribute.

### SHM-008 — transactional unmap

**Decision.** The Client `munmap()`s a sealed Grant **only after** it receives
the matching `COMMITTED`/`ABORTED` reply. Because the Manager holds the fd
(SHM-001), `munmap` removes only *this Client's* mapping — the object and its
data survive, so the Manager can still replay the log into the Store after the
Client is gone (SRS SHM-008 rationale). `munmap` ≠ `shm_unlink`: the latter
destroys the *name*; the object lives as long as any fd is open (§C). The
Client never calls `shm_unlink`.

### SHM-009 — file-backed overlay grants (opt-in pre-ack durability)

**Decision.** When the config requests pre-acknowledgement durability of
uncommitted work, the Grant is backed by a **regular file** (`open()` + `mmap(
MAP_SHARED, filefd)`), not a shm object. `msync(base, log_end, MS_SYNC)` then
pushes the sealed Write Log to the backing file before the Intent Journal
append (TXN-003). Use `MS_SYNC` (blocks to completion); `MAP_NOSYNCFILE` is
*not* set. When the config does not request this, memfd/shm backing is
permitted and msync is a fence only (§SYS-004).

### SHM-010 — snapshot/oplog area: Manager-only writes, immutable after publish

**Decision.** Two enforcement layers:

1. **Kernel-enforced read-only for readers.** Mint reader handles with
   `oflag = O_RDONLY` (CLib `shm_create_handle`) and have Clients map them
   `PROT_READ` only. The kernel then rejects any Client write to the snapshot/
   oplog area — a stronger guarantee than the protocol alone.
2. **Protocol immutability after publish.** The Manager is the sole writer; a
   publish is a single `__atomic_store_n(RELEASE)` of `head_seq`
   (`qr_store_rel`, STUBS). Recall `shm_ctl(SEAL)` does **not** write-protect
   (§A.0 / SYS-003), so do not rely on it for SHM-010.

---

### HDL-001 — OpaqueRef layout

**Decision.** Pure 128-bit value: `region_id (u32) | generation (u32) |
offset (u32) | writer_op_seq (u32)`. No OS calls. Fits in two `int64` words,
packable into a `MsgSendv` iov with no serialization (house pattern).

### HDL-002 — generation-checked resolution

**Decision.** Each process keeps a region table: `region_id → (local_base,
mapped_generation)`. Resolution: look up `region_id`; if missing → only
`MSG_ATTACH_REGION` may satisfy it (HDL-004; the resolver never fabricates a
mapping); if `handle.generation ≠ mapped_generation` → fail **without any
memory access** (return `Stale`). This is the soft ABA guard against Region
recycling.

### HDL-003 — Manager increments generation on reclaim

**Decision.** On reclaim/recycle the Manager (a) **`shm_revoke(fd, pid, …)`**
for each holder's mapping — the revoked mappings are dissociated from backing
memory and any subsequent access `SIGSEGV`s (CLib `shm_revoke`; requires the
object be `SHMCTL_REVOCABLE` + handles minted `NOFD`, per SHM-001/SHM-002) —
and (b) **increments the region's generation** in its own tables and in the
`generation echo` field of any fresh Grant header (RGN-001). Two layers: hard
revoke (kernel) + generation bump (protocol). Note `shm_revoke` revokes **the
whole object** for that pid, not a subrange — so per-Grant revocation implies
one shm object per Grant (or accepting object-granularity revoke). **Open item
(§D):** confirm whether `shm_create_subrange_handle` scopes a revoke to the
subrange on target.

### HDL-004 — miss ⇒ MSG_ATTACH_REGION only

**Decision.** A region-table miss never fabricates a base. The Client sends
`MSG_ATTACH_REGION{region_id}` and the Manager replies with a fresh
`shm_handle_t` (SHM-002 flow). This keeps mapping creation Manager-mediated.

---

### RGN-001 — Grant layout

**Decision.** One contiguous span inside a Region's slab, laid out in order:

```
+----------------------+  <- grant base (region-relative offset G)
| header               |
|   state word         |   Manager-owned, single-writer (RGN-005)
|   seal record        |   (log_end_offset, op_seq) (LOG-005)
|   watermark slot     |   Manager store_rel; Client load_acq (RGN-007/008)
|   generation echo    |   mirrors HDL-003
| file table          |   Manager add-only (RGN-003/004)
| write-log arena     |   Client single-writer while ACTIVE (LOG-001)
| trailing guard page |   Client mprotect PROT_NONE (SHM-005)
+----------------------+
```

The header's hot words (watermark, state, seal) are cache-line padded
(`vclock.ml` house style) to avoid false sharing between Manager writes and
Client acquire-loads (SHM-006 caveat). All sub-structures are addressed as
offsets from `G` (SYS-002).

### RGN-002 — Grant descriptor in MSG_ACQUIRE reply

**Decision.** The reply iov carries: `region_id, generation, size, watermark,
policy flags, file-table capacity, standby availability`, followed by the
serialized `shm_handle_t` (SHM-002). Pure data; built by the Manager, validated
for length by the Client.

### RGN-003 / RGN-004 — File Table (Manager add-only, Client read-only)

**Decision.** File Table slots bind `slot_idx → (file_identity,
base_recipe_ref)` resolved from the Head snapshot at Grant creation. Only the
Manager adds slots (`MSG_ACQUIRE` or `MSG_OPEN_MORE`); the Client treats the
table as read-only. Slot indices make Write Log records compact and
base-relative (LOG-002). The existing `Arena`/`Pmap` offset-indexed accessors
(`Arena.get t i f`) are the house template.

### RGN-005 — Grant state machine

**Decision.** The `state` word traverses exactly:

```
ALLOCATED → ACTIVE → SEALED → (PERSISTED | ABORTED) → UNMAPPED → RECLAIMED
```

Implemented as a checked transition function on the state word (single-writer:
the Manager for `ALLOCATED→ACTIVE`, `SEALED→PERSISTED|ABORTED`, `→UNMAPPED`,
`→RECLAIMED`; the Client fires `ACTIVE→SEALED` via the Seal). Every illegal
edge is rejected. `SEALED→ACTIVE` is forbidden (RGN-006: writes after Seal go
to a standby Grant, never back to ACTIVE).

### RGN-006 — exactly one Seal per Grant

**Decision.** The Seal is a single `__atomic_store_n(RELEASE)` that publishes
`(log_end_offset, op_seq)` into the seal record (`qr_store_rel`, STUBS). After
the Seal, the Client writes only to a **standby Grant** (pre-allocated, handed
out in the same `MSG_ACQUIRE` reply when available — RGN-002 "standby fd"). A
second Seal on the same Grant is rejected by the state machine (RGN-005).

### RGN-007 — Manager-owned, re-armable watermark slot

**Decision.** One word in the header. Manager writes it with
`qr_store_rel`; Client reads it with `qr_load_acq` (SHM-006). The Manager may
**re-arm** it (write a new, larger threshold) while the Grant is `ACTIVE` — a
release-store, so a Client acquire-load either sees the old or the new
threshold, never a torn value. The watermark is advisory-trigger data, not
authority; the Seal (RGN-006) is the authority.

### RGN-008 — watermark condition fires Seal

**Decision.** On every Write Log allocation, the Client compares
`allocation_cursor ≥ watermark` (cursor from `qr_fetch_add`, watermark from
`qr_load_acq`). When true, the Client initiates Seal (RGN-006). This is a
plain-word compare against the acquire-loaded watermark — no syscall, no
pulse, no kernel object. The time-dimension flush (idle writers) is handled
out-of-band by `PULSE_FLUSH` (IPC-091), which the Manager sends as a pulse
(SRS IPC-002: Manager→Client notifications are pulses only, no Region
contents).

---

## B. Test Designs

All host tests extend `test/test.ml`'s `check name bool` harness and link
`qnxml`. They use the **anonymous single-process** `Region.create ~words`
mapping (addr `0n`) where possible, so they run under `dune runtest` on the
Linux host with no QNX. QNX-target tests are flagged and cross-compiled; they
exercise the kernel paths that the host stubs stub out (`qnx_only()`).

Verification keys: **I** = inspection, **A** = analysis, **D** = demonstration,
**T** = test (per SRS §0).

### SHM-001 — Manager retains the fd (I, T)
- **Host (T):** `Region.create ~name:"/vwc_t001" ~words:N ()` in the Manager
  role; `Region.attach ~name:"/vwc_t001"` in a forked child; Client writes a
  sentinel at offset `k`, Manager reads it back → `check "fd-retained: client
  write visible to manager"`. Then Client exits (unmaps); Manager reads the
  sentinel again → `check "object outlives client unmap"` (proves the Manager
  fd, not the Client mapping, owns the lifetime).
- **QNX-target (T):** as above but with `shm_create_handle`/`mmap_handle`
  (SHM-002) and an explicit `shm_ctl(SHMCTL_REVOCABLE)`.

### SHM-002 — handle conveyed in reply (I; T on target)
- **QNX-target (T):** Manager mints `h = shm_create_handle(fd, client_pid, …,
  NOFD)`, replies its bytes; Client `mmap_handle(h)`; Client writes; Manager
  reads → `check "handle-conveyed mapping is the same object"`. Negative: a
  handle minted for `pid_A` opened by `pid_B` via `shm_open_handle_pid` →
  expect failure (`check "handle is pid-bound"`). *(Host has no equivalent;
  the host stub replies raise `QNX-only` — this test is target-only.)*

### SHM-003 — distinct bases (I, T) ⭐ called out
- **Host (T):** parent `Region.create ~name:"/vwc_t003"`, then `Unix.fork`;
  child `Region.attach` at `addr=0n`, prints `Region.base_addr` to a pipe;
  parent attaches at `addr=0n`, reads child's base → `check "bases differ
  across processes"`. Then parent writes at offset `m`, child reads offset
  `m` → `check "offset-relative access works despite distinct bases"`
  (proves SHM-004 simultaneously).
- **QNX-target (T):** replace fork with `posix_spawn` (SKILL warns `fork` is
  safe only single-threaded; the test is single-threaded so fork is tolerated,
  but `posix_spawn` is the portable choice on target).

### SHM-004 — offset 0 ≡ null; relative refs (I, T)
- **Host (T):** `OpaqueRef.null` has `offset = 0`; resolver returns `None` for
  it without dereferencing. A ref with `offset = 12` resolves to
  `base + 12*8`. `check "null offset never dereferenced"` and
  `check "offset is base-relative"`.

### SHM-005 — guard page armed by mapping process (I; T host+target)
- **Host (T):** map a region, `mprotect(base + guard, page, PROT_NONE)` via a
  small stub; install a `SIGSEGV` handler with `sigsetjmp`/`siglongjmp`;
  attempt a write at the guard page → expect caught fault →
  `check "guard page faults on write"`. A write just before the guard
  succeeds → `check "usable span still writable"`.
- **QNX-target (T):** identical, plus assert no `PROCMGR_AID_*` is required
  for `PROT_NONE` (run Client as `qnxuser`).

### SHM-006 — release/acquire visibility (A, T) ⭐ called out
- **Host (T):** one region mapped `MAP_SHARED`; a writer `Thread` does
  `payload.{0} <- sentinel; qr_store_rel region flag_slot 1L`; a reader
  `Thread` spins `while qr_load_acq region flag_slot = 0L do () done` then
  reads `payload.{0}`. Run the reader pinned to a *different* core from the
  writer (host: `pthread_setaffinity`/`taskset`; the house `qr_set_runmask`
  stub pins on QNX). Assert the reader **always** observes `sentinel`
  (release/acquire guarantee), across `N=100_000` iterations. A control loop
  with *plain* (non-atomic) store/load should intermittently fail (or appear
  to) on a weakly-ordered core — document the delta.
- **QNX-target (T):** same, with `qr_set_runmask` pinning writer→CPU0,
  reader→CPU1 (SKILL/multicore.md). This is the meaningful run; x86 host is
  strongly ordered so the host run mostly checks plumbing.

### SHM-007 — msync ordering / durability (T) ⭐ called out
- **Host (T, file-backed approximation):** create a Grant backed by a real
  file on `tmpfs` (`open` + `mmap MAP_SHARED`); writer fills `[0, log_end)`;
  call `msync(MS_SYNC)`; then write the Intent Journal record and `fsync` it.
  *Fault injection:* kill the process (a) before `msync`, (b) after `msync`
  but before journal `fsync`, (c) after journal `fsync`. Re-open: assert that
  in (b) the journal does **not** reference un-`msync`'d bytes, and in (c) it
  does. This proves "visibility ≠ durability" and the msync-before-journal
  ordering (TXN-003).
- **QNX-target (T):** repeat with (i) a **shm-backed** Grant — assert
  `msync`'s absence changes *nothing* about post-crash state (durability is
  the journal's job), and (ii) a **file-backed** overlay Grant (SHM-009) —
  assert `msync(MS_SYNC)` is what makes the range durable. This is the
  power-fail simulation referenced in SRS SHM-007/T.

### SHM-008 — transactional unmap (T)
- **Host (T):** Manager role holds the fd; Client role maps, writes, then
  `munmap`s **before** any "COMMITTED". Manager can still read the bytes (fd
  retained) → `check "client unmap keeps data alive for manager"`. Client then
  re-maps (fresh handle) post-commit and reads the sealed log →
  `check "re-attach after unmap sees committed state"`.

### SHM-009 — file-backed overlay (I, T)
- Covered by the SHM-007 (ii) target test; additionally assert that with
  durability **disabled**, a shm-backed Grant + no-msync path is taken and the
  test still passes the journal-ordering check.

### SHM-010 — Manager-only, immutable-after-publish (A, T)
- **QNX-target (T):** Client maps the snapshot area via an `O_RDONLY` handle
  (`PROT_READ`); attempted `memcpy` write into it → `SIGSEGV` →
  `check "reader handle is kernel read-only"`. Protocol test (host): after the
  Manager's `head_seq` release-store, any further Manager write to that
  published record is a test failure (asserted by a watchpoint-style stub that
  traps writes to published offsets).

### HDL-001 — OpaqueRef is u32×4 (I)
- **Host (T):** `check "OpaqueRef is 128 bits"` (`Bytes.length` of the packed
  encoding = 16); round-trip pack/unpack preserves all four fields.

### HDL-002 — stale generation fails without memory access (T) ⭐ called out
- **Host (T):** region table maps `region_id=7 → (base, gen=3)`. Build a ref
  with `generation=4` (stale) and `offset=42`. Resolver must return `Stale`
  **and** a sentinel at `base+42*8` that the resolver was instructed *not* to
  touch must remain unchanged (instrument the resolver to set a flag if it
  ever computes `base+offset`) → `check "stale handle rejected without
  dereference"`. Positive control: ref with `generation=3` resolves and reads
  the value. Also inject `offset=0` → `check "null ref short-circuits"`.

### HDL-003 — generation++ on reclaim (T)
- **Host (T):** Manager recycles region 7 → `gen` becomes 4. Any outstanding
  ref at `gen=3` now resolves `Stale` (re-uses HDL-002 test). A fresh
  `MSG_ATTACH_REGION` returns `gen=4` and a new base →
  `check "post-reclaim attach returns bumped generation"`.

### HDL-004 — miss ⇒ MSG_ATTACH_REGION only (I)
- **Host (T):** resolver on a region_id absent from the table returns
  `Unmapped` and does **not** fabricate a base (assert the table is unchanged
  and no mapping was created). A mocked `MSG_ATTACH_REGION` is the only way to
  populate the entry.

### RGN-001 — Grant layout (I)
- **Host (T):** allocate a Grant of `words = header + filetable + arena +
  guard`; assert offsets of each sub-structure equal the layout constants; the
  trailing page is page-aligned and exactly one page.

### RGN-002 — MSG_ACQUIRE descriptor fields (I, T)
- **Host (T):** Manager builds the descriptor iov; Client parses and
  `check`s every field round-trips (`region_id, generation, size, watermark,
  policy, ftcap, standby`).

### RGN-003 / RGN-004 — File Table (T / I,T)
- **Host (T):** Manager populates slots from a mock Head; Client reads
  `slot → (identity, base_recipe)`; assert base recipe equals the Head value.
  Client attempts to add a slot → rejected (`check "file table client-add
  rejected"`).

### RGN-005 — state machine (T) ⭐ called out
- **Host (T):** drive `Grant.transition` over every legal edge and assert
  success; drive every illegal edge and assert rejection. Explicitly:
  - legal: `ALLOCATED→ACTIVE`, `ACTIVE→SEALED`, `SEALED→PERSISTED`,
    `SEALED→ABORTED`, `PERSISTED→UNMAPPED`, `ABORTED→UNMAPPED`,
    `UNMAPPED→RECLAIMED`;
  - illegal: `ALLOCATED→SEALED` (skip ACTIVE), `SEALED→ACTIVE` (re-open —
    RGN-006), `PERSISTED→ABORTED`, `RECLAIMED→*` (terminal),
    `ACTIVE→UNMAPPED` (skip seal).
  `check "legal transitions accepted"`; `check "illegal transitions rejected"`
  (one assertion per illegal edge).

### RGN-006 — single Seal; post-seal → standby (T)
- **Host (T):** one Grant, fire Seal once → state `SEALED`, seal record holds
  `(log_end, op_seq)`. Second Seal on same Grant → rejected. A subsequent
  write is routed to the standby Grant (assert the active write cursor of the
  original stays frozen) → `check "post-seal writes target standby"`.

### RGN-007 — watermark re-arm (T)
- **Host (T):** Grant `ACTIVE`, Manager `qr_store_rel watermark = 100`; Client
  `qr_load_acq` → 100. Manager re-arms to `200` mid-flight; Client's next
  acquire-load is either `100` or `200`, never torn (assert across 100k racing
  re-arm/read pairs the observed value is always one of the two published
  values) → `check "watermark re-arm is atomic"`.

### RGN-008 — watermark fires Seal (T) ⭐ called out
- **Host (T):** Grant with `watermark = 64` (set via `qr_store_rel`) and an
  empty arena. Client allocates records via `qr_fetch_add` on the cursor in
  steps of 16 words: after the 4th allocation (cursor `64`) the condition
  `cursor ≥ watermark` is true → assert the Client transitions state to
  `SEALED` and writes the seal record with `log_end = 64`. Negative: with
  `watermark = 80`, five allocations (cursor `80`) → seal at `80`; four
  allocations → no seal. `check "watermark fires seal exactly at threshold"`.

---

## C. QNX-Specific Hazards

- **`mlockall`/`mlock` are no-ops (8.0).** Memory is already wired for the
  process's lifetime (SKILL/memory.md §5; CLib `mlockall`). Keep the calls for
  portability, but **durability ≠ locking** — never reason "I `mlock`'d it so
  it survives." The `qr_lock` stub's boolean return is misleading on QNX
  (always succeeds, does nothing).
- **No `SCM_RIGHTS`.** An fd is a per-process `coid`; you cannot pass an fd in
  a `MsgReply`. Use `shm_create_handle` + `mmap_handle` (SHM-002). Cite
  SKILL/architecture.md §3 + CLib `shm_create_handle`.
- **`MAP_FIXED` requires `PROCMGR_AID_MAP_FIXED`; `PROT_EXEC` requires
  `PROCMGR_AID_PROT_WRITE_AND_EXEC`; `MAP_PHYS` (without `MAP_ANON`) requires
  `PROCMGR_AID_MEM_PHYS`** (SKILL/memory.md §2; CLib `mmap`, `mprotect`).
  VWC uses **none** of these: bases are kernel-chosen (SHM-003), no execute
  (it is data, not code), no physical addressing. Keep Clients unprivileged.
- **`shm_unlink` ≠ `munmap`.** `shm_unlink` removes the *name* from
  `/dev/shmem`; the object (and its pages) persist until the last fd closes
  (SKILL/memory.md §4). Clients must never `shm_unlink`; only the Manager
  does, at final RECLAIM, after closing its own fd. `munmap` removes only the
  calling process's mapping.
- **`shm_revoke` revokes the whole object for a pid**, not a subrange (CLib
  `shm_revoke`), and only mappings created *after* the object is marked
  `SHMCTL_REVOCABLE`. Plan one shm object per revocable Grant, or accept
  object-granularity revoke. Revoked access raises `SIGSEGV` — install a
  handler or treat as fatal per policy.
- **`shm_ctl(SEAL)` does NOT write-protect.** "A sealed object is not
  write-protected" (CLib `shm_ctl`). Do not use it to enforce SHM-010; use
  `O_RDONLY` handles + protocol immutability instead.
- **Pulse, not message, for Manager→Client** (SRS IPC-002; SKILL/architecture.md
  §4). `PULSE_HEAD`/`PULSE_FLUSH` carry `code` + 8-byte `sigval` only — no
  Region contents. Codes must be in `_PULSE_CODE_MINAVAIL.._PULSE_CODE_MAXAVAIL`
  (STUBS `qr_msg_send_pulse` comment). Identical pulses are **compressed** — do
  not count one-pulse-per-event.
- **Never reply to a pulse (`rcvid == 0`); always reply to a message
  (`rcvid > 0`)** on every code path including errors (SKILL/architecture.md §2;
  STUBS `qr_is_pulse`). A missed reply hangs the Client forever.
- **False sharing on the Grant header.** Manager-written watermark/state and
  Client-read cursor on adjacent words thrash the cache (SKILL/multicore.md §4).
  Pad hot header words to their own 64-byte line (`vclock.ml` house style).
- **`fork()` is unsafe from multithreaded processes** (SKILL golden rules).
  Tests that need a second process on target should use `posix_spawn`; the
  single-threaded host tests may use `Unix.fork`.
- **Memory-model reliance.** SHM-006 depends on AArch64 acquire/release
  (`LDAR`/`STLR`). Do not weaken the atomics to plain loads/stores "for
  speed"; on a weakly-ordered core the reader can see the flag without the
  payload. The `__atomic` builtins in `region_stubs.c` are the correct,
  portable choice.
- **`shm_create_handle` consumes a slot against `RLIMIT_SHM_HANDLES_NP`**
  (CLib `shm_create_handle`). A busy Manager minting many handles must raise
  this limit or call `shm_delete_handle` for consumed handles; otherwise
  `MSG_ACQUIRE` starts failing once the limit is hit.
- **Handle is single-use.** `mmap_handle`/`shm_open_handle` can be called once
  per handle (CLib). Do not cache/replay handles; re-mint on each attach.

---

## D. Open Items (on-target verification needed)

1. **Exact `shm_handle_t` size/layout.** The docs describe it opaquely. Confirm
   `sizeof(shm_handle_t)` and that it is a plain-old-data struct safe to copy
   byte-wise into a `MsgReplyv` iov, from the target `<sys/mman.h>`.
2. **`shm_create_subrange_handle` revocation scope.** Does a revoke on the
   parent object revoke the subrange mapping, and can a subrange handle be
   independently `NOFD`/revocable? Determines whether per-Grant hard revoke is
   feasible without one shm object per Grant (HDL-003).
3. **`msync` on `/dev/shmem` objects — actual effect.** Confirm on target that
   `msync(MS_SYNC)` on a pure shm mapping is a pure cache barrier (no I/O, no
   error) so the SHM-007 test's "no-op" branch is honest. Contrast with
   `MAP_NOSYNCFILE` behaviour.
4. **`shm_ctl` flag taxonomy for Grant attributes.** Confirm whether
   `SHMCTL_REVOCABLE` + `SHM_CREATE_HANDLE_OPT_NOFD` is the minimal set to make
   a Manager-minted, Client-consumed, Manager-revocable Grant, and whether any
   ability is required of the *Client* to `mmap_handle` it.
5. **`RLIMIT_SHM_HANDLES_NP` default on the rpi5 BSP** for the `qnxuser`
   account; size the standby-Grant pool (RES-004) against it.
6. **AArch64 cache-line size on Pi 5** for the header padding (assumed 64 B;
   confirm via `sysconf(_SC_LEVEL1_DCACHE_LINESIZE)` and pad header hot words
   accordingly).
7. **Pulse-pool sizing** (`ChannelCreatePulsePool`, SKILL/architecture.md §3)
   for `PULSE_FLUSH` bursts under many idle writers (IPC-091) — confirm no
   `EAGAIN` under load.
8. **`posix_spawn` vs `fork` for the cross-process host/target tests** — pin
   down the exact spawn attribute set (none needed for these tests; document
   for the eventual Client launcher).

---

## Appendix — requirement → decision index

| Req | Decision (§) | QNX API | Verify |
|-----|--------------|---------|--------|
| SYS-001 | A.SYS-001 | name_attach/name_open (or resmgr_attach) | I |
| SYS-002 | A.SYS-002/SHM-004 | OpaqueRef value; offset addressing | I,T |
| SYS-003 | A.SYS-003 | protocol invariant + Seal release-store | A,T |
| SYS-004 | A.SYS-004/SHM-007 | Store+Journal; msync only for file-backed | T,D |
| SYS-005 | A.SYS-005 | generation bump on restart | T |
| SYS-006 | A.SYS-006 | Store-held idempotency key | T |
| SHM-001 | A.SHM-001 | shm_open+ftruncate; Manager fd; shm_ctl REVOCABLE | I,T |
| SHM-002 | A.SHM-002 | shm_create_handle → MsgReplyv → mmap_handle | I (T target) |
| SHM-003 | A.SHM-003 | mmap MAP_SHARED addr=NULL (no MAP_FIXED) | I,T |
| SHM-004 | A.SHM-004 | region-relative offsets; 0=null | I,T |
| SHM-005 | A.SHM-005 | mprotect PROT_NONE by mapping proc (+ subrange handle) | I (T host+target) |
| SHM-006 | A.SHM-006 | __atomic RELEASE/ACQUIRE (qr_store_rel/qr_load_acq) | A,T |
| SHM-007 | A.SYS-004/SHM-007 | msync(MS_SYNC) on file-backed only | T |
| SHM-008 | A.SHM-008 | munmap after reply; Manager fd outlives | T |
| SHM-009 | A.SHM-009 | open()+mmap(MAP_SHARED,filefd) when durable | I,T |
| SHM-010 | A.SHM-010 | O_RDONLY handle + PROT_READ; publish=head_seq release | A,T |
| HDL-001 | A.HDL-001 | pure 128-bit value | I |
| HDL-002 | A.HDL-002 | region table + generation check | T |
| HDL-003 | A.HDL-003 | shm_revoke + generation++ | T |
| HDL-004 | A.HDL-004 | miss ⇒ MSG_ATTACH_REGION | I |
| RGN-001 | A.RGN-001 | header/ftable/arena/guard in slab | I |
| RGN-002 | A.RGN-002 | descriptor iov in MSG_ACQUIRE reply | I,T |
| RGN-003/004 | A.RGN-003/004 | slot table, Manager add-only | T / I,T |
| RGN-005 | A.RGN-005 | checked state word | T |
| RGN-006 | A.RGN-006 | single Seal release-store; standby | T |
| RGN-007 | A.RGN-007 | watermark word store_rel/load_acq | T |
| RGN-008 | A.RGN-008 | cursor≥watermark ⇒ Seal | T |
