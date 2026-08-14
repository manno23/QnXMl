# VWC-SRS-001 — Virtual Working Copy Subsystem
## Software Requirements Specification

| Field            | Value                                              |
|------------------|----------------------------------------------------|
| Document ID      | VWC-SRS-001                                        |
| Revision         | A (draft)                                          |
| System           | Virtual Working Copy (VWC) subsystem               |
| Parent design    | VWC-SDD-001 (shm-snapshot-cow-spec.md)             |
| Scope            | Shared-memory working-copy layer, client/manager   |
|                  | IPC protocol, transactional persistence to CAS     |
| Verification key | I = Inspection, A = Analysis, D = Demonstration,   |
|                  | T = Test                                           |

Conventions: each requirement contains exactly one "shall" statement and is
individually verifiable. "Client" denotes a writer process linked against the
VWC client library. "Manager" denotes the single server process. Trace links
point to the parent requirement each item decomposes.

---

## 1. Definitions

**Region** — a kernel shared-memory object (memfd or file-backed) mapped
MAP_SHARED by one or more processes. **Grant** — a Region allocated by the
Manager to one Client for one transaction, together with its policy
descriptor. **OpaqueRef** — the 128-bit cross-process reference defined in
§4. **File Table** — the per-Grant array binding Client file slots to base
recipe references. **Write Log** — the temporal, append-only record stream
within a Grant. **Seal** — the single release-store that renders a Grant's
Write Log immutable. **Head** — the newest published operation.
**Store** — the SQLite-backed content-addressed persistent store.
**Intent Journal** — the fsync'd fixed-record commit journal.

---

## 2. System-Level Requirements (VWC-SYS)

[VWC-SYS-001] The subsystem shall consist of exactly one Manager process and
zero or more Client processes per repository instance.
  Rationale: single serializer eliminates operation-log contention.
  Verify: I

[VWC-SYS-002] Processes shall exchange memory references exclusively as
OpaqueRefs; a virtual address shall never cross a process boundary.
  Rationale: mappings are placed independently (ASLR); addresses are not
  portable; opacity prevents forged access.
  Verify: I (API audit), T

[VWC-SYS-003] Every shared Region shall operate under exactly one of two
write disciplines: single-writer, or immutable-after-publish.
  Rationale: eliminates all multi-writer memory; sole concurrency
  primitives are release/acquire publication pairs.
  Verify: A (design audit), T (race detector)

[VWC-SYS-004] The Store shall be the sole durability authority; all shared-
memory content shall be reconstructible from the Store and Intent Journal.
  Rationale: shared memory is volatile; power loss must resolve to the last
  durable operation.
  Verify: T (kill/restart), D

[VWC-SYS-005] Manager unavailability shall affect only liveness of new
commits, never integrity of committed state.
  Verify: T (manager kill during load)

[VWC-SYS-006] Commit handling shall be idempotent with respect to the key
(writer_id, writer_op_seq).
  Rationale: crash/retry and duplicate delivery must be safe.
  Verify: T (duplicate injection)

---

## 3. Shared-Memory Architecture (VWC-SHM)      [trace: SYS-002, SYS-003]

[VWC-SHM-001] The Manager shall create every Region as a kernel object
(memfd_create on Linux; shm object on QNX) and shall retain an open
descriptor to it for the Region's entire lifetime.
  Rationale: Manager-held descriptor keeps physical frames alive
  independent of Client mappings (enables SHM-008).
  Verify: I, T

[VWC-SHM-002] Region descriptors shall be conveyed to Clients only within
IPC replies (SCM_RIGHTS on Linux; shm handle on QNX).
  Verify: I

[VWC-SHM-003] Clients shall map Regions MAP_SHARED at an unspecified base
address and shall make no assumption of address equality across processes.
  Verify: I, T (forced distinct bases)

[VWC-SHM-004] All intra-Region references shall be Region-relative offsets;
offset 0 shall encode null.
  Verify: I, T

[VWC-SHM-005] Memory protection changes on a Region (e.g., guard-page
arming) shall be performed only by the mapping process, as directed by the
Grant descriptor.
  Rationale: protections are per-address-space; remote mprotect is
  impossible and shall not be assumed.
  Verify: I

[VWC-SHM-006] Cross-process visibility of Region contents shall be
established solely by release-store/acquire-load pairs on designated
publication fields; no syscall shall be required for visibility.
  Verify: A (memory-model review), T

[VWC-SHM-007] Durability of Region contents, where required (SHM-009),
shall be established by msync of the dirty ranges prior to the dependent
Intent Journal append; visibility (SHM-006) shall not be treated as
durability.
  Verify: T (power-fail simulation)

[VWC-SHM-008] A Client shall unmap a sealed Grant only after receiving the
corresponding COMMITTED or ABORTED reply.
  Rationale: "transactional free" — unmap is the Client's commit-scope
  release; Manager's descriptor (SHM-001) guarantees the data outlives it.
  Verify: T

[VWC-SHM-009] Overlay Grants shall be file-backed when the configuration
enables pre-acknowledgement durability of uncommitted work; otherwise
memfd backing is permitted.
  Verify: I, T

[VWC-SHM-010] The published snapshot area and the operation-log area shall
be written only by the Manager and shall be immutable after publication.
  Verify: A, T

---

## 4. OpaqueRef Handle (VWC-HDL)                [trace: SYS-002]

[VWC-HDL-001] The OpaqueRef shall be a 128-bit value comprising region_id
(u32), generation (u32), offset (u32), and writer_op_seq (u32).
  Verify: I

[VWC-HDL-002] Handle resolution shall consult the per-process region table
(region_id → local base, mapped generation) and shall fail, without memory
access, when the handle generation differs from the mapped generation.
  Rationale: prevents use-after-reclaim (ABA) across GC recycling.
  Verify: T (stale-handle injection)

[VWC-HDL-003] The Manager shall increment a Region's generation upon every
reclamation or recycling of that Region.
  Verify: T

[VWC-HDL-004] A region-table miss during resolution shall be satisfied only
via MSG_ATTACH_REGION; the resolver shall never fabricate a mapping.
  Verify: I

---

## 5. Grant, File Table, and Lifecycle (VWC-RGN) [trace: SYS-003]

[VWC-RGN-001] Each Grant shall contain, in order: a header (state word,
seal record, Manager-owned watermark slot, generation echo), a File Table,
a Write Log arena, and an optional trailing guard page.
  Verify: I

[VWC-RGN-002] The Grant descriptor returned by MSG_ACQUIRE shall specify
region_id, generation, size, watermark, policy flags, File Table capacity,
and standby-grant availability.
  Verify: I, T

[VWC-RGN-003] The File Table shall bind each slot index to the file's
identity and to the base recipe reference resolved from the Head snapshot
at Grant creation.
  Rationale: the Grant mirrors the previously persisted file state; slot
  indices make Write Log records compact and base-relative.
  Verify: T

[VWC-RGN-004] File Table slots shall be added only by the Manager
(MSG_ACQUIRE or MSG_OPEN_MORE); Clients shall treat the table as read-only.
  Verify: I, T

[VWC-RGN-005] A Grant shall traverse only the states ALLOCATED → ACTIVE →
SEALED → (PERSISTED | ABORTED) → UNMAPPED → RECLAIMED, in that order.
  Verify: T (state-machine test)

[VWC-RGN-006] Exactly one Seal shall occur per Grant; writes issued by the
Client after its Seal shall target only a standby Grant.
  Verify: T

[VWC-RGN-007] The Manager-owned watermark slot shall be writable only by
the Manager and shall be re-armable while the Grant is ACTIVE.
  Rationale: manager-prepared, locally-fired commit trigger.
  Verify: T (live re-arm)

[VWC-RGN-008] The Client shall evaluate the watermark condition
(allocation cursor ≥ watermark) on every Write Log allocation and shall
initiate Seal upon the condition becoming true.
  Verify: T

---

## 6. Write Log Format (VWC-LOG)                [trace: RGN-001]

[VWC-LOG-001] Write Log records shall be appended strictly in modification
order (temporal order), independent of target file offsets.
  Rationale: sequential memory writes; replay order is implicit; layout is
  deliberately non-linear with respect to file layout.
  Verify: I, T

[VWC-LOG-002] Each record shall contain: magic, slot_idx, file_offset,
length, monotonic seq, CRC32C over header+payload, payload bytes.
  Verify: I, T

[VWC-LOG-003] For overlapping byte ranges within one Grant, the record
with the greater seq shall supersede.
  Verify: T

[VWC-LOG-004] Any per-file index maintained in the Grant shall be
advisory; the Write Log shall be the sole authoritative content.
  Rationale: Manager replay depends only on checksummed records.
  Verify: A, T

[VWC-LOG-005] The Seal record shall publish (log_end_offset, op_seq) via a
single release-store to the Grant header.
  Verify: T

[VWC-LOG-006] A record failing CRC validation, and all records after it,
shall be excluded from replay.
  Rationale: torn-tail truncation semantics under power loss.
  Verify: T (fault injection)

---

## 7. IPC Protocol (VWC-IPC)                     [trace: SYS-001]

Transport: QNX native — ChannelCreate/ConnectAttach; synchronous
MsgSend/MsgReceive/MsgReply; pulses for asynchronous notification.
Linux — SOCK_SEQPACKET Unix socket with SCM_RIGHTS; eventfd doorbells.

[VWC-IPC-001] All Client-initiated operations shall use the synchronous
send/receive/reply pattern; the Client shall remain reply-blocked until the
Manager replies.
  Rationale: kernel-enforced backpressure; on QNX, priority inheritance
  applies to the blocked send.
  Verify: I, T

[VWC-IPC-002] Manager-initiated notifications shall use pulses (or
doorbells) only and shall carry no Region contents.
  Verify: I

[VWC-IPC-003] The Manager shall service commit requests in per-channel
receive order; this order shall define the total order of operations.
  Verify: T (concurrent commit ordering)

Message catalog — each message shall conform to its row:

| ID  | Message           | Dir | Payload → Reply                          |
|-----|-------------------|-----|------------------------------------------|
| 010 | MSG_ATTACH        | C→M | credentials → session_id, snapshot fd    |
| 011 | MSG_ATTACH_REGION | C→M | region_id → fd, generation, length       |
| 020 | MSG_ACQUIRE       | C→M | paths[], size_hint → Grant fd, OpaqueRef,|
|     |                   |     | descriptor (RGN-002), standby fd (opt.)  |
| 021 | MSG_OPEN_MORE     | C→M | OpaqueRef, paths[] → new slot indices    |
| 030 | MSG_COMMIT        | C→M | OpaqueRef, base_op_seq, meta →           |
|     |                   |     | COMMITTED{op_id, op_seq, standby fd}     |
|     |                   |     | | CONFLICT{slots[]} | FAULT{code}        |
| 031 | MSG_ABORT         | C→M | OpaqueRef → ok                           |
| 040 | MSG_DETACH        | C→M | session_id → ok                          |
| 090 | PULSE_HEAD        | M→C | new head_seq                             |
| 091 | PULSE_FLUSH       | M→C | request Seal at next boundary            |

[VWC-IPC-010] MSG_ATTACH shall establish a session and return the current
Head snapshot Region descriptor.
  Verify: T

[VWC-IPC-020] MSG_ACQUIRE shall populate the File Table (RGN-003) from the
Head current at processing time and shall record that Head as the Grant's
base_op_seq.
  Verify: T

[VWC-IPC-030] The Manager shall reply COMMITTED only after the Store
transaction for that operation has been made durable (TXN-004).
  Verify: T (power-fail between store commit and reply)

[VWC-IPC-031] On MSG_COMMIT bearing an already-committed
(writer_id, writer_op_seq), the Manager shall re-reply the prior COMMITTED
result without re-executing.
  Trace: SYS-006. Verify: T

[VWC-IPC-032] A CONFLICT reply shall identify every conflicting File Table
slot and the Head operation that superseded its base.
  Verify: T

[VWC-IPC-091] Upon PULSE_FLUSH, the Client shall Seal at its next
allocation boundary or reply-with MSG_ABORT within the configured bound.
  Rationale: size triggers cannot fire on idle writers; the time dimension
  requires cooperative flush.
  Verify: T

---

## 8. Transaction and Durability (VWC-TXN)       [trace: SYS-004]

[VWC-TXN-001] Commit processing shall execute strictly in the order:
(1) idempotency check, (2) handle/generation validation, (3) acquire-load
of Seal, (4) Intent Journal append with fsync, (5) log replay and merge
against base, (6) content-defined re-chunking of superseded ranges only,
(7) single Store transaction containing chunks, recipes, trees, commit,
view, and operation row, (8) shared-memory publication, (9) reply.
  Verify: T (step-order instrumentation)

[VWC-TXN-002] The Intent Journal record shall be fixed-size and shall
contain writer_id, writer_op_seq, the OpaqueRef, base_op_seq, and a CRC.
  Verify: I, T

[VWC-TXN-003] When SHM-009 durability is enabled, the msync of the sealed
Write Log ranges shall complete before the Intent Journal append.
  Verify: T (ordering fault injection)

[VWC-TXN-004] All persistent objects of one operation shall be committed
in exactly one Store (SQLite WAL) transaction.
  Rationale: single fsync point; no multi-file ordering.
  Verify: T

[VWC-TXN-005] Shared-memory publication (snapshot area, operation record,
head_seq release-store) shall occur only after TXN-004 durability.
  Rationale: shared memory shall never lead the Store.
  Verify: T

[VWC-TXN-006] Where base_op_seq precedes Head, the Manager shall proceed
when the operation's touched slots are disjoint from all intervening
operations, and shall otherwise apply the configured policy
(merge-at-file-granularity or CONFLICT).
  Verify: T

---

## 9. Failure Management (VWC-FLT)               [trace: SYS-004, SYS-005]

[VWC-FLT-001] The Manager shall detect Client termination via the
transport's disconnect indication (QNX disconnect pulse; Linux pidfd/
socket hangup) and shall transition that Client's Grants to ABORTED or,
where a durable Seal and Intent record exist, optionally to PERSISTED per
configured policy.
  Verify: T (client kill matrix)

[VWC-FLT-002] On restart, the Manager shall (1) open the Store, (2)
rebuild the snapshot and operation-log Regions from the Store, (3) replay
Intent Journal records absent from the Store, discarding those failing
LOG-006 validation, (4) increment generations of all pre-restart Regions,
and only then (5) accept sessions.
  Verify: T (restart under load)

[VWC-FLT-003] Clients shall respond to generation-validation failure by
re-attaching and re-issuing unacknowledged commits.
  Trace: SYS-006, HDL-002. Verify: T

[VWC-FLT-004] Power loss at any instant shall resolve, after FLT-002, to a
state equal to the last durable operation plus zero or more fully-replayed
intents; no partial operation shall be observable.
  Verify: T (systematic power-fail campaign), A

---

## 10. Resource Management (VWC-RES)             [trace: SYS-004]

[VWC-RES-001] Each attached process shall publish, in a single-writer
control slot, the oldest operation sequence it may still read.
  Verify: I, T

[VWC-RES-002] The Manager shall reclaim a published Region only when every
attached process's published sequence exceeds that Region's sequence, and
shall then apply HDL-003.
  Verify: T

[VWC-RES-003] Store garbage collection shall retain the closure (view,
commits, trees, recipes, chunks) of every operation reachable from the
configured retention roots and shall delete objects only outside that
closure, in bounded batches.
  Verify: T, A

[VWC-RES-004] The count and aggregate size of concurrently outstanding
Grants shall be bounded by configuration; MSG_ACQUIRE beyond the bound
shall block or fail per policy, never over-allocate.
  Rationale: bounded resources for deterministic behavior.
  Verify: T

---

## 11. Verification Cross-Reference

| Group   | I | A | D | T | Notes                                   |
|---------|---|---|---|---|-----------------------------------------|
| SYS     | 2 | 1 | 1 | 4 | race detector on SYS-003                |
| SHM     | 6 | 2 | — | 7 | power-fail sim on SHM-007               |
| HDL     | 2 | — | — | 3 | stale-handle fuzzing                    |
| RGN     | 3 | — | — | 6 | state-machine model test                |
| LOG     | 2 | 1 | — | 5 | CRC fault injection                     |
| IPC     | 3 | — | — | 8 | duplicate-delivery + ordering tests     |
| TXN     | 1 | — | — | 6 | step-order instrumentation, pull-plug   |
| FLT     | — | 1 | — | 4 | kill matrix, restart-under-load         |
| RES     | 1 | 1 | — | 4 | reclamation soak                        |

Open items for Revision B: numeric bounds (watermark defaults, Grant size
ranges, PULSE_FLUSH response bound, Intent Journal rotation), QNX shm
handle specifics vs. Linux memfd, and CONFLICT policy selection matrix.
