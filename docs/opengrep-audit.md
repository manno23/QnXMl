# QnXMl opengrep audit

Date: 2026-08 (opengrep 1.10.0)
Scope: `lib/` (6 OCaml modules + 1 C stub), `demo/`, `test/`, `qcon.py` — 1,197 LOC.

## Resolution status (2026-11)

The findings below are the original audit. Current code addresses them as follows. Host tests cover each row that can run on Linux; QNX-only IPC is compiled behind `__QNXNTO__` and returns `-ENOTSUP` on the host.

| id | status | where |
|---|---|---|
| E1 | **fixed** | `Vclock.merge` is a CAS-max loop; `Vclock.tick` stays `fetch_add`. A tick that linearizes after a merge is `max+1` (a later event). `Region.atomic_max_self_test` runs the same race under pthreads, because host systhreads hold the runtime lock and cannot interleave the OCaml loop. |
| E2 | **fixed** | `MsgSendPulse` returns `-errno` (`EAGAIN` included). The producer pulses only after a push, and only if the consumer has published a sleeper flag (`Wake.arm`): CAS the flag 1→0, pulse once, and on EAGAIN put the flag back. The consumer release-stores the flag before it rechecks the ring, so a drain-then-sleep cannot miss the wakeup. |
| W1 | **fixed** | Attach `fstat`s and returns `Too_small` when `st_size` is short. No touch past the object. |
| W2 | **fixed** | Create is `O_CREAT\|O_EXCL`. An existing object is `Exists` and is not `ftruncate`d. `ftruncate` runs only on the brand-new fd. The syntactic opengrep rule still matches that `ftruncate` call; the unsafe "resize a live object" path is gone. |
| W3 | **fixed** | Nonzero `addr` uses `MAP_FIXED_NOREPLACE`, or `Fixed_unsupported` where that flag does not exist. No silent `MAP_FIXED` clobber. |
| W4 | **fixed** | `MsgSendv`'s reply iov is the caller-supplied bigarray. The demo prints the ack word. The syntactic rule still matches the `MsgSendv` call itself. |
| W5 | **fixed** | `Ring.attach` rejects non-positive cap/width or a slice that cannot hold them. |
| W6 | **fixed** | `Merkle.update` release-stores the root last; `root` acquire-loads it. A proof walks children afterward and is consistent only while the writer is quiescent (`merkle.mli`), not as a concurrent snapshot. |
| W7 | **fixed** | Runmask shift is range-checked before the shift. |
| I1 | **fixed** | Hot paths do not box. `test/test.ml` asserts `Gc.minor_words` delta 0 and 0 minor collections for Ring push+pop, Arena alloc/free, Pmap set, Pmap find, Vclock tick/compare/merge, and Merkle update. |
| I2 | **documented** | Counters are 63-bit OCaml ints on purpose (`ring.mli`, `region.mli`). Not widened. |
| I3 | **fixed** | `Retry.until` plus producer/consumer deadlines. A dead creator is not "ready". |
| I4 | **already gone** | No zero-length `memset` in `region_stubs.c`. |
| I5 | **fixed** | Arena free CAS-es an allocated flag; double-free and out-of-range free return false. |
| I6 | **fixed** | `Vclock.pack` writes the dense wire vector. `compare`/`merge` still take that dense form. |
| I7 | **fixed** | `qcon.py` exits unless `QNXML_QCONN=1`. Host comes from argv or `QNXML_QCONN_HOST`. |
| stale session (`shell-capture.txt` `Failure("ConnectAttach")`) | **fixed** | `connect_attach` returns `-errno`. The consumer unmaps and retries until the handshake deadline. `Region.recover` holds an exclusive flock on a sibling shm for the whole check-and-replace, so a second producer cannot unlink a live replacement. A creator pid that is still alive (published or not) yields `Busy`. Failed `attach` validation `munmap`s before returning. |

Pmap readers must not hold a root across a concurrent `set` that retires it. There is no epoch reclamation yet; the mli states that quiescence contract. VWC itself is still interfaces only.

## Method

| source | what | result |
|---|---|---|
| opengrep registry `--config auto` | 1,074 rules (only 58 applicable: 7 OCaml, 5 C) | 0 findings |
| `semgrep/semgrep-rules` + `opengrep/opengrep-rules` community | 99 OCaml/C rules | 4 findings — all false positives (`memset` flagged as insecure-wipe; both sites are intentional pre-fault/no-op memsets, not secret erasure) |
| `trailofbits/semgrep-rules` | no C/C++/OCaml coverage (Go/Python/JS/Swift) | n/a |
| **`tools/opengrep/qnxml.yml` (project rules, 14 rules)** | written for this audit | **41 findings** |
| manual deep review of all 1,197 lines | concurrency + stub semantics | findings below |

Parser note: tree-sitter C cannot parse `CAMLprim value` (two consecutive
identifiers), so `region_stubs.c` is only partially analyzed in-place.
`make opengrep` therefore scans a `sed`-transformed copy
(`CAMLprim value` → `static value`) which parses with zero errors and
reproduces identical findings.

---

## Findings, by severity

### ERROR — real races / contract violations

#### E1. `Vclock.merge` is a non-atomic check-then-store racing the owner's `fetch_add`
**lib/vclock.ml:65** — `if b > a then Region.store_rel t.s (component_ix i) b`

`merge` does an acquire-**load**, compares, then a release-**store** — that is
not an atomic RMW. Component `i` is concurrently ticked by peer `i` via
`fetch_add` (atomic). Interleavings from state `a=5`, incoming `b=10`:

| order | result | correct? |
|---|---|---|
| store(10) then fetch_add(+1) | **11** | ✗ inflated past max(10, 6) |
| fetch_add(+1)→6 then store(10) | 10 | ✓ |

Inflation makes the local clock claim progress it never made → later deltas
get classified `After` (stale) and **silently dropped**. The atomic toolkit in
`Region` (`load_acq`/`store_rel`/`fetch_add`) cannot express a max; the fix is
a CAS loop — add a `qr_compare_exchange` stub and loop in `merge`.

#### E2. `MsgSendPulse` EAGAIN crashes the producer under backpressure
**lib/region_stubs.c:280** — `caml_failwith("MsgSendPulse")`

Producer's full-ring loop (`demo/producer.ml`: `while not (Ring.push …) do
notify () done`) fires a pulse **per failed push**. If the consumer is preempted
and the ring stays full, the receiver's kernel pulse pool exhausts →
`MsgSendPulse` returns EAGAIN → the stub raises → the producer dies exactly
when it is merely backpressured. Return the error to OCaml; coalesce/rate-limit
wakeups on the caller side (one pulse per empty→full transition is enough).

### WARNING — hazards with concrete trigger paths

#### W1. No size validation on attach → SIGBUS, not an error
**lib/region_stubs.c (`qr_map`, attach path)** — `attach` mmaps `words*8` bytes
against an existing shm object **without fstat-ing its actual size**. If
producer and consumer disagree on `total_words` (code skew between processes),
`mmap` succeeds and the first touch past the object's end delivers SIGBUS.
Check `st_size >= bytes` on attach and fail cleanly.

#### W2. `O_CREAT` + `ftruncate` silently resizes shared state
**lib/region_stubs.c:65** — a `create=true` call on an existing object
ftruncates it to the new size; another live participant's data is truncated or
the object grows with zero-fill. The demo papers over this with
`Region.unlink` before create, but the library contract doesn't. Use `O_EXCL`
for create, or fstat-and-verify.

#### W3. `MAP_FIXED` silently destroys overlapping mappings
**lib/region_stubs.c:70** — a wrong `~addr` hint replaces whatever was mapped
there with no error. Prefer `MAP_FIXED_NOREPLACE` (handle EEXIST), or probe
first. (Check QNX support — on Linux this exists since 4.17.)

#### W4. `MsgSendv` reply payload is collected and discarded
**lib/region_stubs.c:~197-207** — replies land in stack-local `int64_t
reply[8]` that is never read, while the comment claims "small reply into a
caller buffer". `demo/consumer.ml` even prints `rc` as "ack received (%d reply
bytes)" — the ack content is fiction. Either return the reply words to OCaml
or drop the reply iov and say sends are ack-only.

#### W5. `Ring.attach` trusts `cap`/`width` from the region
**lib/ring.ml:42-44** — plain reads (no acquire, no validation). Attaching to a
not-yet-initialized slice yields `cap = 0` and `Division_by_zero` deep inside
`slot_base` instead of a clean failure at attach. Validate `cap > 0`,
`width > 0` at attach.

#### W6. Merkle tree has no publication discipline
**lib/merkle.ml** — `update` writes leaf→root with plain stores; `root` is read
plain. If any cross-process reader compares roots while an update is in flight,
it can observe a new root over stale children (or a torn path) → false
divergence → spurious resync. Either release-store the root / acquire-load it,
or state the quiescence requirement explicitly in the interface.

#### W7. Unchecked shift amount
**lib/region_stubs.c:303** — `(uintptr_t)1 << Long_val(vcpu)` is UB for
`vcpu >= 64`. Clamp/validate.

### INFO — honesty-of-contract and hardening

#### I1. "Zero OCaml heap allocation in steady state" is overstated
- **Ring hot path boxes int64s**: `Region.load_acq` returns a boxed int64
  (`caml_copy_int64` in the stub) and `push`/`pop` box again via
  `Int64.of_int` — ~3 minor allocations per push at full rate. At 1M msg/s the
  minor GC runs constantly. Fix if it matters: OCaml supports `[@@unboxed]`
  externals for int64 args/results (`external load_acq : words -> int ->
  (int64 [@unboxed])`), which removes both the argument and result boxes — the
  C signature becomes a plain `int64_t` in/out.
- **Pmap allocates per set**: the copy log is a heap list consed per copied
  node (`log := i :: !log`), plus the version-window list. The strongest claim
  holds for Ring/Arena/Vclock/Merkle payloads, not for Pmap's bookkeeping —
  scope the README wording or move the log into the region.

#### I2. 63-bit truncation of shared counters
**lib/ring.ml:48-72, demo/*.ml** — counters are `int64` in the region but
`Int64.to_int`-ed before arithmetic, so the "monotone, never wrapped"
invariant actually holds to 2^62 on the OCaml side; past that, `mod` goes
negative and indexing raises rather than corrupting. ~144,000 years at 1M
msg/s — document it, don't fix it.

#### I3. Liveness: no timeouts in startup handshakes
**demo/producer.ml:51** (`while load_acq hdr 3 = 0L do sleepf …`) and
**demo/consumer.ml:19** (attach retry) both spin forever if the peer dies at
the wrong moment. Fine for a demo; a production handshake wants a deadline.

#### I4. `memset(p, 0, 0)` is dead code
**lib/region_stubs.c:77** — a zero-length memset does nothing; the pre-fault is
the volatile loop below it. Remove the memset (it also trips generic
"insecure memset" rules into false positives).

#### I5. Arena free-list has no corruption detection
**lib/arena.ml:34-38** — `free` trusts the handle; a double-free or wild
handle silently corrupts the intrusive free list. The Pmap retirement argument
(each node appears in exactly one `replaced` log because `ins` only walks the
newest root) is sound, but a debug-mode poison word in freed nodes would turn a
future regression into a loud failure instead of silent garbage.

#### I6. Dense-wire vs padded-resident vclock format is enforced by prose
**lib/vclock.ml** — `compare`/`merge` expect a *dense* n-word vector; the
resident copy is padded one counter per cache line. A peer that MsgSends its
resident slice instead of a packed staging vector feeds stride-mismatched
garbage into `compare`. A `pack`/`unpack` helper pair in the module would make
the contract un-missable.

#### I7. `qcon.py` — unauthenticated remote shell by design
Plaintext qconn launcher client; remote code execution is its purpose. Safe
only because the dev image starts qconn deliberately. Rule: qconn must never
ship in a production image; consider gating this script behind an env check.
(Community Python rules: 0 findings — the hazard is protocol-level, invisible
to pattern matching.)

---

## Verified correct (negative results worth recording)

- **Ring memory ordering** — textbook SPSC: producer's release-store of `tail`
  publishes payload writes; consumer's acquire-load of `tail` pairs with it;
  consumer's release-store of `head` is acquired by the producer before reusing
  a slot. head/tail on separate 64-byte lines; the padding arithmetic
  (`header_words = 11`) matches. No missing fence found.
- **Runtime-lock discipline in stubs** — every potentially blocking call
  (`MsgSendv`, `MsgReceive`, `MsgReplyv`, `MsgSendPulse`) sits inside
  `caml_release_runtime_system`/`caml_acquire_runtime_system`; non-blocking
  ones don't need it. The dedicated opengrep rule was proven non-vacuous
  against a synthetic violating stub, then returned clean on the real file.
- **CAMLparam/CAMLlocal hygiene** — allocation points (`caml_ba_alloc_dims`,
  `caml_alloc_tuple`, `caml_copy_*`) are properly rooted; bigarray data
  pointers taken before releasing the runtime lock point outside the GC heap,
  so they stay valid across the blocking section.
- **Pmap retirement invariant** — a copied node is referenced only by versions
  ≤ the copied-from version (successors share the copy, never the original),
  so freeing `successor.replaced` when the oldest retires is exact; a node can
  appear in only one `replaced` log because `ins` only walks the newest root.
  The 1,000-version churn test peaking at 79/4,096 nodes corroborates.
- **Pulse decode endianness** — extracting code from bits 32–39 of word 0
  matches `struct _pulse` on the little-endian aarch64le target (would break on
  a BE target — acceptable, target is pinned).
- **Producer publish order** — pid/chid are release-stored before the magic
  flag; consumer side mirrors it (chid word before pid flag). Acquire on magic
  then reads the full control plane. Correct release-sequence.
- **`qr_msg_receive` bounds-checks the destination against the region before
  the kernel copies** — message-validation rule satisfied at the only place it
  can be violated.
- **`msg_receive` result tuple** built after re-acquiring the runtime lock.

## Recommendations, ranked

1. **E1** — add `qr_compare_exchange` stub; rewrite `Vclock.merge` as an atomic
   max CAS loop. (Correctness of the whole delta-discard logic hangs on this.)
2. **E2** — make `MsgSendPulse` non-fatal; coalesce producer wakeups.
3. **W1** — fstat size check on attach (SIGBUS → clean error).
4. **W4** — return or remove the MsgSendv reply buffer.
5. **W5/W6** — attach-time validation in `Ring.attach`; document or implement
   Merkle publication order.
6. **I1** — scope the zero-allocation claim in README; optionally `[@@unboxed]`
   the int64 externals.
7. Rest (W2, W3, W7, I2–I7) as hardening permits.

## Reproduce

```
make opengrep          # community + tools/opengrep/qnxml.yml (41 findings)
opengrep scan --config auto lib demo test   # registry
```
