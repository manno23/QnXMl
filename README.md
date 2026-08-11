# qnx_ocaml — preallocated incremental-compute structures for QNX

Four data structures for a distributed, delta-passing QNX application, in
OCaml, over one preallocated / page-locked / optionally fixed-address memory
region. Steady state allocates **zero** OCaml heap: if the region is sized
right at init, the GC has nothing to collect and never runs during operation.

```
              ONE SLAB (mmap'd, pre-faulted, mlock'd, carved at init)
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
| `Region`  | mmap + pre-fault + mlock, bump-carved slices     | all page faults at init; monotone allocator refuses post-init surprises |
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

Host (Linux, for logic tests):
```
ocamlopt -c region_stubs.c
ocamlopt region_stubs.o region.ml ring.ml arena.ml pmap.ml vclock.ml merkle.ml test.ml -o test -cclib -lrt
./test
```

QNX target (SDP with OCaml cross-toolchain, or build under a QNX-hosted
OCaml): compile the stubs with `qcc` for your target and link as above:
```
qcc -Vgcc_ntoaarch64le -c region_stubs.c -I$(ocamlopt -where)
```
`shm_open`, `mmap`, `mlock` are POSIX and native on Neutrino; shared objects
appear under `/dev/shmem/`. The `MsgSendv`/`MsgReceive`/`MsgReply` wrappers
compile only under `__QNXNTO__` (host builds keep the symbols and fail loudly
if called). Note `qr_msg_send` points its iov **directly at the region**, so
a delta send is: write words into your staging slice, one kernel call, no
serialization layer anywhere.

## Placement & determinism notes (the "position" part)

- **Fixed addressing**: pass `~addr` to `Region.create`/`attach` for
  `MAP_FIXED`, giving every process the identical mapping so word indices
  are absolute cross-process references. Choose the address from your
  system's memory map (outside default heap/stack/library ranges); on QNX
  you can additionally use POSIX typed memory (`posix_typed_mem_open`) to
  draw the backing store from a named physical region defined in your BSP's
  syspage — swap the `shm_open` in `qr_map` for that fd and nothing else
  changes.
- **Locking**: `qr_map` pre-faults every page at init and `mlock`s the
  range; check the `locked` flag. For belt-and-braces on QNX add
  `mlockall(MCL_CURRENT)` after all regions are mapped.
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
