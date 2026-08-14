# VWC-OCaml — Traceability Matrix

Implementation of **VWC-SRS-001 (Rev A)** — Virtual Working Copy Subsystem.
Each requirement carries its verification keys (I/A/D/T); the matrix below
maps every requirement to the OCaml module (or POC) that implements/proves it.
Spec text: `docs/VWC-SRS-001.md`. Source of truth for lanes: `lib/`, POCs:
`poc/`, tests: `test/`.

## Legend
- Module column = implementation module. `core/*` = `lib/core`, `ipc/*` = `lib/ipc`, `sys/*` = `lib/sys`.
- POC column = proof-of-concept executable under `poc/`.
- T = test under `test/`.
- Keys: I = inspection, A = analysis, D = demonstration, T = test.

## §2 System (VWC-SYS)

| Req | Module | POC / T | Key | Notes |
|-----|--------|---------|-----|-------|
| SYS-001 | `sys/manager`, `sys/client` | POC1 | I | one Manager, N Clients |
| SYS-002 | `core/opref` | POC1, T | I,T | OpaqueRef-only crossing; no raw addrs |
| SYS-003 | `core/grant`, `core/writelog` | POC2 | A,T | single-writer OR immutable-after-publish |
| SYS-004 | `ipc/store`, `ipc/journal` | POC3 | T,D | Store + Intent Journal = sole durability |
| SYS-005 | `sys/manager` | T (kill test) | T | manager death ≠ corruption |
| SYS-006 | `sys/manager` (idempotent commit) | POC1, T | T | (writer_id, writer_op_seq) idempotency |

## §3 Shared Memory (VWC-SHM)

| Req | Module | POC / T | Key |
|-----|--------|---------|-----|
| SHM-001 | `core/region` (+ `region_stubs.c`) | POC1 | I,T |
| SHM-002 | `ipc/ipc` (fd/shm handle in reply) | T | I |
| SHM-003 | `core/region` (MAP_SHARED, no addr equality) | T | I,T |
| SHM-004 | `core/opref` (region-relative offsets; 0=null) | T | I,T |
| SHM-005 | `core/grant` (guard page arm by mapping proc) | T | I |
| SHM-006 | `core/region` (release-store/acquire-load publish) | POC1 | A,T |
| SHM-007 | `ipc/store` (msync before journal append) | POC3 | T |
| SHM-008 | `sys/client` (unmap sealed grant after reply) | POC1 | T |
| SHM-009 | `core/grant` (file-backed overlay grants) | POC3 | I,T |
| SHM-010 | `sys/manager` (snapshot/oplog area immutable) | POC2 | A,T |

## §4 OpaqueRef (VWC-HDL)

| Req | Module | POC / T | Key |
|-----|--------|---------|-----|
| HDL-001 | `core/opref` (u32×4: region_id, generation, offset, writer_op_seq) | T | I |
| HDL-002 | `core/region` (per-proc table; generation check) | T (stale-handle) | T |
| HDL-003 | `sys/manager` (generation++ on reclaim) | T | T |
| HDL-004 | `sys/client` (miss → MSG_ATTACH_REGION only) | T | I |

## §5 Grant / File Table / Lifecycle (VWC-RGN)

| Req | Module | POC / T | Key |
|-----|--------|---------|-----|
| RGN-001 | `core/grant` (header, file table, log arena, guard) | T | I |
| RGN-002 | `ipc/ipc` (MSG_ACQUIRE reply descriptor) | T | I,T |
| RGN-003 | `core/filetable` (slot → identity + base recipe) | T | T |
| RGN-004 | `sys/manager` (table add-only by Manager) | T | I,T |
| RGN-005 | `core/grant` (state machine) | T (state machine test) | T |
| RGN-006 | `core/grant` (single seal; post-seal → standby) | POC1 | T |
| RGN-007 | `core/grant` (manager watermark slot, re-arm) | T | T |
| RGN-008 | `sys/client` (watermark check on each alloc) | POC2 | T |

## §6 Write Log (VWC-LOG)

| Req | Module | POC / T | Key |
|-----|--------|---------|-----|
| LOG-001 | `core/writelog` (temporal append order) | POC2 | I,T |
| LOG-002 | `core/writelog` (record: magic, slot, offset, len, seq, CRC32C, payload) | T | I,T |
| LOG-003 | `ipc/store` (greater seq supersedes) | POC2 | T |
| LOG-004 | `core/filetable` (index advisory; log authoritative) | T | A,T |
| LOG-005 | `core/grant` (seal publishes (log_end, op_seq) release-store) | POC1 | T |
| LOG-006 | `ipc/store` (CRC fail → truncate tail) | POC3 | T |

## §7 IPC Protocol (VWC-IPC)

| Req | Module | POC / T | Key |
|-----|--------|---------|-----|
| IPC-001 | `ipc/ipc`, `sys/client` (sync send/receive/reply) | POC1 | I,T |
| IPC-002 | `ipc/ipc` (pulses/doorbells only for M→C) | POC1 | I |
| IPC-003 | `sys/manager` (per-channel order = total order) | POC2 | T |
| IPC-010 | `ipc/ipc` MSG_ATTACH | T | T |
| IPC-020 | `ipc/ipc` MSG_ACQUIRE | T | T |
| IPC-030 | `sys/manager` (COMMITTED only after durable TXN-004) | POC3 | T |
| IPC-031 | `sys/manager` (re-reply prior COMMITTED) | POC1, T | T |
| IPC-032 | `ipc/ipc` CONFLICT reply (slots + head op) | POC2 | T |
| IPC-091 | `sys/client` (PULSE_FLUSH → seal at boundary) | POC2 | T |

## §8 Transaction & Durability (VWC-TXN)

| Req | Module | POC / T | Key |
|-----|--------|---------|-----|
| TXN-001 | `sys/manager` (9-step commit order) | POC1, T | T |
| TXN-002 | `ipc/journal` (fixed record: writer_id, op_seq, ref, base, CRC) | T | I,T |
| TXN-003 | `ipc/store` (msync before journal) | POC3 | T |
| TXN-004 | `ipc/store` (single LMDB write txn per op) | POC3 | T |
| TXN-005 | `sys/manager` (publish after durability) | POC3 | T |
| TXN-006 | `sys/manager` (base < head: disjoint slots OK else policy) | POC2 | T |

## §9 Failure (VWC-FLT)

| Req | Module | POC / T | Key |
|-----|--------|---------|-----|
| FLT-001 | `sys/manager` (disconnect → ABORTED/PERSISTED) | T (kill matrix) | T |
| FLT-002 | `sys/manager` (restart: store → rebuild → replay journal → gen++) | POC3 | T |
| FLT-003 | `sys/client` (generation fail → re-attach + re-issue) | T | T |
| FLT-004 | `ipc/store`+`ipc/journal` (power-loss resolution) | POC3 | A,T |

## §10 Resource (VWC-RES)

| Req | Module | POC / T | Key |
|-----|--------|---------|-----|
| RES-001 | `core/region` (per-proc single-writer seq slot) | T | I,T |
| RES-002 | `sys/manager` (reclaim only past all published seqs) | T | T |
| RES-003 | `ipc/store` (GC closure + bounded batches) | T | T,A |
| RES-004 | `sys/manager` (bounded outstanding grants) | T | T |

## POCs (Demos)

| POC | File | Proves |
|-----|------|--------|
| 1 — transaction & consistency | `poc/poc1_transaction.ml` | SYS-001/002/006, SHM-006/008, RGN-006, LOG-005, IPC-001/002/031, TXN-001 |
| 2 — concurrent op sequencing | `poc/poc2_oplog_seq.ml` | SYS-003, SHM-010, RGN-008, LOG-001/003, IPC-003/032/091, TXN-006 |
| 3 — LMDB persistence (immutable + reversible) | `poc/poc3_lmdb_persist.ml` | SYS-004/005, SHM-007/009, LOG-006, IPC-030, TXN-003/004/005, FLT-002/004 |
