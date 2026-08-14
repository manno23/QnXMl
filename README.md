# qnxml & vwc: functional systems architecture & capabilities on qnx

an exploration into applying **functional programming techniques, persistent data structures, and object capability (ocap) security models** as first-class operating system primitives on the **qnx neutrino 8.0** real-time microkernel.

---

## 1. vision & common goal

modern systems programming frequently struggles with the friction between mutable in-place state, ambient-authority security vulnerabilities, and non-deterministic latency spikes caused by runtime garbage collection or lock contention. 

this project explores how **qnx's microkernel architecture** (strict process isolation, synchronous message-passing ipc, and pre-faulted wired memory) can be combined with **functional language principles** (pure immutability, structural sharing, append-only logs, and capability-guarded references) to solve these core challenges:
1. **functional primitives as os building blocks**:
   instead of viewing persistence and functional data structures as high-level application abstractions, we implement them directly over shared kernel memory. persistent treaps, version vectors, and merkle hash trees operate with zero runtime heap allocation, turning functional immutability into a real-time os primitive.
2. **object capability (ocap) security model**:
   eliminating ambient authority (such as global file paths, uids, or raw cross-process memory pointers). access to any memory slice, channel, or persistent resource is authorized solely by possession of an unforgeable, generation-counted capability handle (`opaqueref`).
3. **hard real-time & microkernel alignment**:
   marrying ocaml’s expressive type system with qnx’s deterministic rtos primitives (`msgsendv` / `msgreceive`, non-blocking pulses, `sched_fifo` priority scheduling, and wired memory), demonstrating that a high-level typed functional language can behave as a zero-gc, bare-metal systems language.

---

## 2. virtual working copy (vwc) subsystem

the **virtual working copy (`vwc_ocaml`)** subsystem implements a high-assurance, transactional state persistence engine influenced by **jujutsu (jj)**, **mosaic**, and **qnx message-passing process isolation**, governed under an **object capability security model**.
the "working copy" [https://docs.jj-vcs.dev/latest/working-copy] is a concept from jujutsu's version control system.

```
   ┌─────────────────────────────────────────────────────────────────────────────┐
   │                        object capability model (ocap)                       │
   │  • unforgeable 128-bit opaquerefs: (region_id, generation, offset, op_seq)  │
   │  • zero ambient authority (no raw virtual addrs, no global file paths)      │
   │  • instant temporal revocation via generation bumping (no use-after-free)   │
   └──────────────────────────────────────┬──────────────────────────────────────┘
                                          │
   ┌──────────────────────────────────────▼──────────────────────────────────────┐
   │              jujutsu & mosaic-style state persistence layer                 │
   │  • ephemeral working copies (grants) decoupled from canonical repository dag│
   │  • temporal write log: append-only delta stream with crc32c validation      │
   │  • atomic seal & commit: linear operation log (oplog) with reversible ops   │
   │  • durability: lmdb single write-txn + wal-free metapage commit & journal   │
   └──────────────────────────────────────┬──────────────────────────────────────┘
                                          │
   ┌──────────────────────────────────────▼──────────────────────────────────────┐
   │                  qnx message passing & memory substrate                     │
   │  • strict process isolation; disjoint address spaces (aslr)                 │
   │  • synchronous msgsendv / msgreceive / msgreply + non-blocking pulses        │
   │  • single-manager serializer eliminates multi-process locking contention    │
   │  • qnxml substrate: preallocated shm slabs, spsc rings, zero gc steady-state│
   └─────────────────────────────────────────────────────────────────────────────┘
```

### key architectural pillars of vwc

- **jujutsu & mosaic working-copy model**:
  working copies are not dirty disk checkouts, but ephemeral, capability-guarded projections (**grants**) over immutable base snapshots. writers append delta records to an authoritative **temporal write log** (`(slot, offset, len, seq, payload, crc32c)`). canonical state is never mutated in-place.
- **object capability (ocap) access (`opaqueref`)**:
  references crossing process boundaries are strictly 128-bit unforgeable capabilities:
  ```ocaml
  type t = {
    region_id : int32;      (* identifies the kernel shm object *)
    generation : int32;     (* incremented on recycling / revocation *)
    offset : int32;         (* region-relative byte offset; 0 = null *)
    writer_op_seq : int32;  (* op sequence this handle was created under *)
  }
  ```
  possession of the handle *is* authorization. stale capabilities are instantly invalidated on lookup (`result.error `stale`) when a grant is recycled, preventing cross-process use-after-free.
- **single-manager serializer & qnx ipc**:
  a single manager process coordinates commits and grants, eliminating distributed lock contention. message passing uses synchronous `msgsendv`/`msgreplyv` pointing straight into shared slabs, with non-blocking qnx pulses for async notifications and disconnect detection.
- **two-phase deterministic durability**:
  upon transaction seal, the manager verifies crc32c checksums, writes a fixed-size record to an append-only **intent journal**, executes an atomic single-transaction commit to the **lmdb content-addressed store**, and publishes the new head snapshot.

---

## 3. adapting ocaml as a systems language on qnx

the **`qnx_ocaml`** substrate provides the foundational, zero-allocation data structures and qnx kernel bindings that make functional programming safe and deterministic in a hard real-time environment.

```
             one slab (mmap'd, pre-faulted at init, carved —
             mlock kept for linux parity, a no-op on qnx 8.0)
 ┌──────────┬─────────────┬───────────┬──────────┬───────────────────┐
 │ ring     │ arena       │ vclock    │ merkle   │ (msg staging,     │
 │ spsc     │ treap nodes │ per-peer  │ 2n hash  │  scratch...)      │
 │ ingress  │ = pmap pool │ counters  │ words    │                   │
 └──────────┴─────────────┴───────────┴──────────┴───────────────────┘
        all indices are ints → valid cross-process, invisible to gc,
        and already wire-format for msgsendv iovs pointed at the slab
```

### preallocated shared-memory primitives

| module | purpose | real-time / systems guarantee |
|---|---|---|
| **`region`** | pre-faulted shared-memory mapping | monotone bump allocator at init; zero page faults during steady state. |
| **`ring`** | bounded spsc ring buffer | wait-free push/pop via acquire/release atomic fences (`qr_load_acq`/`qr_store_rel`). |
| **`arena`** | fixed-capacity node pool | o(1) allocation and recycling via an intrusive free list; hard memory bounds. |
| **`pmap`** | persistent treap with sliding window | bounded-window copy-log recycling reconciles path-copying persistence with fixed arenas without gc tracing. |
| **`vclock`** | region-backed version vector | monotone peer counters for causality tracking across distributed cores. |
| **`merkle`** | implicit heap hash tree | o(log n) delta re-hashing; 1-word cross-node state consistency verification. |

### memory management & determinism on qnx

1. **zero-heap steady state (gc elimination)**:
   all operational data lives in off-heap, preallocated `bigarray` slabs of `int64` words. because steady-state execution allocates no ocaml heap blocks, the ocaml gc has zero work to collect and remains completely idle during operation.
2. **offset-based handle addressing**:
   word indices and `opaqueref` handles are region-relative integer offsets rather than absolute virtual addresses. this allows processes with differing aslr mappings to safely share structures without pointer translation or relocation tables.
3. **zero-copy kernel ipc (`msgsendv` / `msgreplyv`)**:
   `region_stubs.c` bridges qnx message passing directly to `region` slabs. i/o vectors point straight at slice memory, allowing delta publication and rpc replies in a single syscall with zero intermediate serialization or copying.
4. **real-time scheduling & cpu affinity**:
   native c stubs configure `sched_fifo` priorities (bounded $\le 63$ for unprivileged users) and bmp runmasks (`set_runmask`) to bind critical threads to dedicated cores on multi-core targets (e.g. raspberry pi 5 cortex-a76).

---

## 4. repository layout

```text
qnxml/
├── dune-project          # declares packages: qnx_ocaml and vwc_ocaml
├── makefile              # unified make targets (host, target, demo, test)
├── .envrc                # ocaml 5.3.0 switch + qnx sdp 8.0 environment
├── qcon.py               # qnx target deployment & test harness
│
├── lib/                  # layer 0/1: qnx_ocaml substrate primitives
│   ├── region.ml / .mli  # pre-faulted shm slabs & bump carving
│   ├── region_stubs.c    # qnx ipc (msgsendv/receive), atomics, shm bindings
│   ├── ring.ml           # wait-free spsc ring
│   ├── arena.ml          # fixed-pool intrusive allocator
│   ├── pmap.ml           # copy-log persistent treap
│   ├── vclock.ml         # region version vector
│   └── merkle.ml         # in-slab hash tree
│
├── vwc/                  # layer 2: vwc_ocaml subsystem (virtual working copy)
│   ├── lib/              # core interfaces: opref, grant, writelog, filetable, ipc
│   ├── docs/             # vwc-srs-001 requirements, trace matrix, impl specs
│   ├── poc/              # proof-of-concept executables (poc1..poc3)
│   ├── test/             # srs requirement verification tests
│   └── vendor/           # vendored lmdb engine for qnx aarch64
│
├── demo/                 # two-process shm demo over qnx channel/pulse plane
├── docs/                 # substrate specifications & cross-compilation guides
└── test/                 # substrate unit tests & benchmarks
```

---

## 5. building & verification

### host build (linux)
run unit tests and the spsc shared-memory demo:
```bash
make host    # runs dune build & dune test across all workspace packages
make demo    # launches producer/consumer processes over shared memory
```

### qnx target cross-compilation (raspberry pi 5 / aarch64)
cross-compiles against qnx sdp 8.0:
```bash
source .envrc
make target  # builds the 'qnx' dune cross-compilation context
```
smoke test c stubs directly against neutrino headers:
```bash
qcc -vgcc_ntoaarch64le -c lib/region_stubs.c -i$(ocamlopt -where)
```
