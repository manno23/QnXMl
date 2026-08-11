# qnx_ocaml — preallocated incremental-compute structures for QNX

Four data structures for a distributed, delta-passing QNX application, in
OCaml, over one preallocated, pre-faulted shared-memory region (optionally
mapped at a fixed address; see “Placement” below). Steady state allocates
**zero** OCaml heap: if the region is sized right at init, the GC has
nothing to collect and never runs during operation.

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

## Modules

| module    | what                                            | key guarantee |
|-----------|--------------------------------------------------|---------------|
| `Region`  | mmap + pre-fault, bump-carved slices (mlock shim: no-op on QNX 8.0) | all page faults at init; monotone allocator refuses post-init surprises |
| `Ring`    | bounded SPSC ring, acq/rel publication           | wait-free push/pop, exact full/empty via monotone counters |
| `Arena`   | fixed pool, intrusive free list, int handles     | O(1) alloc/free, hard capacity = your preallocation contract |
| `Pmap`    | persistent treap, sliding version window         | old-version reads intact; O(diff) retirement bounds the pool |
| `Vclock`  | fixed-peer version vector in region              | monotone by construction (no `set`, only `tick`/`merge`) |
| `Merkle`  | implicit-heap hash tree over pooled leaves       | O(log N) rehash per delta; 1-word cross-node consistency check |

The one non-obvious design point is in `Pmap`: path-copying persistence
normally fights preallocation (every update allocates). The reconciliation is
the **copy log** — each new version records which node indices it copied
over; those are referenced only by strictly older versions, so when the
window slides, freeing the successor's log is exact garbage collection in
O(nodes replaced), no tracing, no GC. Bounded window × bounded arena =
bounded memory *by construction*. The test drives 1,000 versions through a
4,096-node arena and peaks at 79 nodes in use.

## Building

Host (Linux, for logic tests) — dune project, library in `lib/`, suite in
`test/`, two-process shm demo in `demo/`:
```
make host    # dune build && dune test
make demo    # producer/consumer over the named shm ring, on this machine
```

QNX target (SDP with OCaml cross-toolchain, or build under a QNX-hosted
OCaml): `make target` builds the `qnx` dune cross context — toolchain setup
and known header friction points are in `docs/CROSS.md`. The stubs alone can
be smoke-tested against Neutrino headers with:
```
qcc -Vgcc_ntoaarch64le -c lib/region_stubs.c -I$(ocamlopt -where)
```
`shm_open`, `mmap`, `mlock` are POSIX and native on Neutrino; shared objects
appear under `/dev/shmem/`. (`mlock` is a no-op on QNX 8.0 — all process
memory is already wired — so the calls are kept for Linux/host parity,
where locking is real.) The `MsgSendv`/`MsgReceive`/`MsgReply` wrappers
compile only under `__QNXNTO__` (host builds keep the symbols and fail loudly
if called). Note `qr_msg_send` points its iov **directly at the region**, so
a delta send is: write words into your staging slice, one kernel call, no
serialization layer anywhere.

## Placement & determinism notes (the "position" part)

- **Addressing**: word indices are *offsets within each process's own
  mapping*, not absolute virtual addresses — the library never
  dereferences a remote index, so each process's Bigarray base can sit
  anywhere and the indices still agree. Fixed addressing (pass `~addr` to
  `Region.create`/`attach` for `MAP_FIXED`, giving every process the
  identical mapping) remains available for features that genuinely need
  identical placement — a debugger, or a zero-copy hardware path — but it
  is **deferred for the POC** (default `addr = 0n`): on QNX it costs the
  `PROCMGR_AID_MAP_FIXED` ability for an unprivileged process, plus the
  collision risk of picking an address outside heap/stack/libraries, and
  buys no correctness here. (Typed memory — `posix_typed_mem_open` for a
  named physical pool — is likewise deferred to a later milestone if a
  contiguity/DMA requirement appears; the POC uses `shm_open`.)
- **Locking / no runtime page faults**: on QNX 8.0, `mlock`/`mlockall` are
  no-ops — all process memory is already wired — so the `locked` flag reads
  `true` vacuously and asserting it buys nothing. The real guarantee comes
  from (a) the pre-fault touch loop in `qr_map` (every page is faulted in
  at init, never at runtime) and (b) QNX's wired-memory model. The `mlock`
  call and `locked` flag are kept for Linux/host parity, where locking is
  real; on QNX, log the flag, don't assert it.
- **GC posture**: steady state should allocate nothing (the structures
  don't; keep your driving code free of closures/boxing in hot paths —
  int64 Bigarray access and int arithmetic compile clean). Then set a
  modest fixed minor heap (`OCAMLRUNPARAM=s=256k`) and the collector is
  simply idle. If you do allow small steady-state allocation, that minor
  size bounds pause length instead.
- **SPSC discipline**: `Ring` is single-producer/single-consumer — one
  ring per direction per peer, which is also the natural shape for a QNX
  channel-per-service design. The only fences are the acq/rel stubs on
  head/tail; payload words are plain stores ordered by the release.

## Honest caveats

- `Merkle`'s mixer detects corruption/divergence between trusting nodes;
  it is not adversarially collision-resistant. Same interface, swap in
  BLAKE3 via a stub if you need integrity against attackers.
- `Pmap.retire_oldest` assumes linear history (a single writer per shard) —
  which is the resource-manager-owns-its-shard model. Branching histories
  need refcounts.
- `Vclock.compare`/`merge` are per-component atomic but not atomic as a
  vector; in the intended single-writer-per-component use this is sound.
