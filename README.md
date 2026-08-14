# QnXMl & VWC: Functional Systems Architecture & Capabilities on QNX

An exploration into applying **functional programming techniques, persistent data structures, and Object Capability (OCap) security models** as first-class operating system primitives on the **QNX Neutrino 8.0** real-time microkernel.

---

## 1. Vision & Common Goal

Modern systems programming frequently struggles with the friction between mutable in-place state, ambient-authority security vulnerabilities, and non-deterministic latency spikes caused by runtime garbage collection or lock contention. 

This project explores how **QNX's microkernel architecture** (strict process isolation, synchronous message-passing IPC, and pre-faulted wired memory) can be combined with **functional language principles** (pure immutability, structural sharing, append-only logs, and capability-guarded references) to solve these core challenges:

1. **Functional Primitives as OS Building Blocks**:
   Instead of viewing persistence and functional data structures as high-level application abstractions, we implement them directly over shared kernel memory. Persistent treaps, version vectors, and Merkle hash trees operate with zero runtime heap allocation, turning functional immutability into a real-time OS primitive.
2. **Object Capability (OCap) Security Model**:
   Eliminating ambient authority (such as global file paths, UIDs, or raw cross-process memory pointers). Access to any memory slice, channel, or persistent resource is authorized solely by possession of an unforgeable, generation-counted capability handle (`OpaqueRef`).
3. **Hard Real-Time & Microkernel Alignment**:
   Marrying OCaml’s expressive type system with QNX’s deterministic RTOS primitives (`MsgSendv` / `MsgReceive`, non-blocking pulses, `SCHED_FIFO` priority scheduling, and wired memory), demonstrating that a high-level typed functional language can behave as a zero-GC, bare-metal systems language.

---

## 2. Virtual Working Copy (VWC) Subsystem

The **Virtual Working Copy (`vwc_ocaml`)** subsystem implements a high-assurance, transactional state persistence engine influenced by **Jujutsu (jj)**, **Mosaic**, and **QNX message-passing process isolation**, governed under an **Object Capability security model**.

```
   ┌─────────────────────────────────────────────────────────────────────────────┐
   │                        Object Capability Model (OCap)                       │
   │  • Unforgeable 128-bit OpaqueRefs: (region_id, generation, offset, op_seq)  │
   │  • Zero ambient authority (no raw virtual addrs, no global file paths)      │
   │  • Instant temporal revocation via generation bumping (no use-after-free)   │
   └──────────────────────────────────────┬──────────────────────────────────────┘
                                          │
   ┌──────────────────────────────────────▼──────────────────────────────────────┐
   │              Jujutsu & Mosaic-Style State Persistence Layer                 │
   │  • Ephemeral Working Copies (Grants) decoupled from canonical repository DAG│
   │  • Temporal Write Log: append-only delta stream with CRC32C validation      │
   │  • Atomic Seal & Commit: linear operation log (oplog) with reversible ops   │
   │  • Durability: LMDB single write-txn + WAL-free metapage commit & Journal   │
   └──────────────────────────────────────┬──────────────────────────────────────┘
                                          │
   ┌──────────────────────────────────────▼──────────────────────────────────────┐
   │                  QNX Message Passing & Memory Substrate                     │
   │  • Strict process isolation; disjoint address spaces (ASLR)                 │
   │  • Synchronous MsgSendv / MsgReceive / MsgReply + non-blocking pulses        │
   │  • Single-Manager serializer eliminates multi-process locking contention    │
   │  • QnXMl substrate: preallocated shm slabs, SPSC rings, zero GC steady-state│
   └─────────────────────────────────────────────────────────────────────────────┘
```

### Key Architectural Pillars of VWC

- **Jujutsu & Mosaic Working-Copy Model**:
  Working copies are not dirty disk checkouts, but ephemeral, capability-guarded projections (**Grants**) over immutable base snapshots. Writers append delta records to an authoritative **temporal Write Log** (`(slot, offset, len, seq, payload, CRC32C)`). Canonical state is never mutated in-place.
- **Object Capability (OCap) Access (`OpaqueRef`)**:
  References crossing process boundaries are strictly 128-bit unforgeable capabilities:
  ```ocaml
  type t = {
    region_id : int32;      (* identifies the kernel shm object *)
    generation : int32;     (* incremented on recycling / revocation *)
    offset : int32;         (* region-relative byte offset; 0 = null *)
    writer_op_seq : int32;  (* op sequence this handle was created under *)
  }
  ```
  Possession of the handle *is* authorization. Stale capabilities are instantly invalidated on lookup (`Result.Error `Stale`) when a Grant is recycled, preventing cross-process use-after-free.
- **Single-Manager Serializer & QNX IPC**:
  A single Manager process coordinates commits and grants, eliminating distributed lock contention. Message passing uses synchronous `MsgSendv`/`MsgReplyv` pointing straight into shared slabs, with non-blocking QNX pulses for async notifications and disconnect detection.
- **Two-Phase Deterministic Durability**:
  Upon transaction seal, the Manager verifies CRC32C checksums, writes a fixed-size record to an append-only **Intent Journal**, executes an atomic single-transaction commit to the **LMDB content-addressed store**, and publishes the new Head snapshot.

---

## 3. Adapting OCaml as a Systems Language on QNX

The **`qnx_ocaml`** substrate provides the foundational, zero-allocation data structures and QNX kernel bindings that make functional programming safe and deterministic in a hard real-time environment.

```
             ONE SLAB (mmap'd, pre-faulted at init, carved —
             mlock kept for Linux parity, a no-op on QNX 8.0)
 ┌──────────┬─────────────┬───────────┬──────────┬───────────────────┐
 │ Ring     │ Arena       │ Vclock    │ Merkle   │ (msg staging,     │
 │ SPSC     │ treap nodes │ per-peer  │ 2N hash  │  scratch...)      │
 │ ingress  │ = Pmap pool │ counters  │ words    │                   │
 └──────────┴─────────────┴───────────┴──────────┴───────────────────┘
        all indices are ints → valid cross-process, invisible to GC,
        and already wire-format for MsgSendv iovs pointed at the slab
```

### Preallocated Shared-Memory Primitives

| Module | Purpose | Real-Time / Systems Guarantee |
|---|---|---|
| **`Region`** | Pre-faulted shared-memory mapping | Monotone bump allocator at init; zero page faults during steady state. |
| **`Ring`** | Bounded SPSC ring buffer | Wait-free push/pop via acquire/release atomic fences (`qr_load_acq`/`qr_store_rel`). |
| **`Arena`** | Fixed-capacity node pool | O(1) allocation and recycling via an intrusive free list; hard memory bounds. |
| **`Pmap`** | Persistent treap with sliding window | Bounded-window copy-log recycling reconciles path-copying persistence with fixed arenas without GC tracing. |
| **`Vclock`** | Region-backed version vector | Monotone peer counters for causality tracking across distributed cores. |
| **`Merkle`** | Implicit heap hash tree | O(log N) delta re-hashing; 1-word cross-node state consistency verification. |

### Memory Management & Determinism on QNX

1. **Zero-Heap Steady State (GC Elimination)**:
   All operational data lives in off-heap, preallocated `Bigarray` slabs of `int64` words. Because steady-state execution allocates no OCaml heap blocks, the OCaml GC has zero work to collect and remains completely idle during operation.
2. **Offset-Based Handle Addressing**:
   Word indices and `OpaqueRef` handles are region-relative integer offsets rather than absolute virtual addresses. This allows processes with differing ASLR mappings to safely share structures without pointer translation or relocation tables.
3. **Zero-Copy Kernel IPC (`MsgSendv` / `MsgReplyv`)**:
   `region_stubs.c` bridges QNX message passing directly to `Region` slabs. I/O vectors point straight at slice memory, allowing delta publication and RPC replies in a single syscall with zero intermediate serialization or copying.
4. **Real-Time Scheduling & CPU Affinity**:
   Native C stubs configure `SCHED_FIFO` priorities (bounded $\le 63$ for unprivileged users) and BMP runmasks (`set_runmask`) to bind critical threads to dedicated cores on multi-core targets (e.g. Raspberry Pi 5 Cortex-A76).

---

## 4. Repository Layout

```text
QnXMl/
├── dune-project          # Declares packages: qnx_ocaml and vwc_ocaml
├── Makefile              # Unified make targets (host, target, demo, test)
├── .envrc                # OCaml 5.3.0 switch + QNX SDP 8.0 environment
├── qcon.py               # QNX target deployment & test harness
│
├── lib/                  # Layer 0/1: qnx_ocaml substrate primitives
│   ├── region.ml / .mli  # Pre-faulted shm slabs & bump carving
│   ├── region_stubs.c    # QNX IPC (MsgSendv/Receive), atomics, shm bindings
│   ├── ring.ml           # Wait-free SPSC ring
│   ├── arena.ml          # Fixed-pool intrusive allocator
│   ├── pmap.ml           # Copy-log persistent treap
│   ├── vclock.ml         # Region version vector
│   └── merkle.ml         # In-slab hash tree
│
├── vwc/                  # Layer 2: vwc_ocaml subsystem (Virtual Working Copy)
│   ├── lib/              # Core interfaces: opref, grant, writelog, filetable, ipc
│   ├── docs/             # VWC-SRS-001 requirements, trace matrix, IMPL specs
│   ├── poc/              # Proof-of-concept executables (POC1..POC3)
│   ├── test/             # SRS requirement verification tests
│   └── vendor/           # Vendored LMDB engine for QNX aarch64
│
├── demo/                 # Two-process shm demo over QNX channel/pulse plane
├── docs/                 # Substrate specifications & cross-compilation guides
└── test/                 # Substrate unit tests & benchmarks
```

---

## 5. Building & Verification

### Host Build (Linux)
Run unit tests and the SPSC shared-memory demo:
```bash
make host    # Runs dune build & dune test across all workspace packages
make demo    # Launches producer/consumer processes over shared memory
```

### QNX Target Cross-Compilation (Raspberry Pi 5 / AArch64)
Cross-compiles against QNX SDP 8.0:
```bash
source .envrc
make target  # Builds the 'qnx' dune cross-compilation context
```
Smoke test C stubs directly against Neutrino headers:
```bash
qcc -Vgcc_ntoaarch64le -c lib/region_stubs.c -I$(ocamlopt -where)
```
