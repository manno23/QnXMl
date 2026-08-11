# QnXMl — Specification, Direction Assessment, and POC Plan

Status: proposal for team review. Not a release artifact.
Sources of truth consulted (in order):
- `/home/jm/data/qnx/.pi/skills/qnx-os-and-application-design/SKILL.md` + `references/{architecture,memory,processes-threads-scheduling,multicore,timing,api-navigation}.md` (hereafter **design-skill / design-skill:memory.md** etc.)
- `/home/jm/data/qnx/.pi/skills/qnx-project-development/SKILL.md` + `references/{development-workflow,make-conventions,bsp-and-images,target-operations,project-governance}.md` (hereafter **dev-skill / dev-skill:bsp-and-images.md** etc.)
- Project: `README.md`, `docs/CROSS.md`, `lib/{region,ring,arena,pmap,vclock,merkle}.ml`, `lib/region_stubs.c`, `demo/{producer,consumer,layout}.ml`
- Real build/deploy path: `/home/jm/data/qnx/qnx_custom_builds/NOTES.md`, `README.md`, `Makefile`, `targets/rpi5/{variables.mk,mkqnximage.config}`, `example-qnx-project/{Makefile,NEXT_STEP.md}` (the **CTI** = Custom Target Image build system)

Verified environment (recorded, per dev-skill:project-governance.md):
- Host: Debian trixie, Linux x86_64 (`uname -a` 2026-07-04 kernel).
- OCaml 5.3.0 via opam switch `ocaml-base-compiler.5.3.0` (`.envrc`).
- QNX SDP 8.0 staged by CTI at `/home/jm/data/qnx/qnx_custom_builds/qnx800`; `qnxsdp-env.sh` present (46 lines); `qcc -V` lists `12.2.0,gcc_ntoaarch64le`. Target triple: `aarch64-unknown-nto-qnx8.0.0`.
- Target: Raspberry Pi 5 (BCM2712, 4× Cortex-A76, aarch64le), CTI image `build/rpi5/rpi5.img`, hostname `qnxpi`, dev access `qnxuser@192.168.208.80` over cgem0 ethernet.

---

## A. Direction assessment

The project's core thesis — one preallocated slab, all structures inside it,
word indices as cross-process handles, deltas sent as `MsgSendv` iovs pointed
at the slab — is **compatible with QNX 8.0 practice and defensible**, but
four claims in the docs need correction, and the design is missing the
control/notification plane that QNX idiom supplies. Findings ranked by
importance:

### A.1 mlock/mlockall are no-ops on QNX 8.0; README presents them as a guarantee — **docs are wrong, side with the skills**

- Skills: design-skill golden rule "`mlockall()`/`mlock()` are no-ops in QNX
  8.0 — all process memory is already wired"; design-skill:memory.md §5
  "mlockall() does nothing and always returns 0 in this release. Keep the
  calls for portability; they are no-ops here."
- Project: README header "mmap'd, pre-faulted, **mlock'd**"; Region row
  "mmap + pre-fault + mlock ... all page faults at init"; "qr_map pre-faults
  every page at init and **mlocks the range; check the `locked` flag**. For
  belt-and-braces on QNX add `mlockall(MCL_CURRENT)`". `region_stubs.c`
  `qr_lock` claims locking "prevents lazy mapping surprises".
- **Verdict: side with the skills.** On QNX the `locked` flag will always
  read `true` (no-op returns 0) and buys nothing; the property that matters
  — no runtime page faults — comes from (a) the pre-fault touch loop in
  `qr_map` and (b) QNX 8.0's all-memory-wired model. Keep `mlock` in the C
  for host/Linux parity (where it is real), but the README must be reframed:
  mlock is a portability shim, not a QNX guarantee. The `locked` flag should
  be logged, not asserted.

### A.2 Typed memory vs `shm_open` for the slab — **project's default is right; typed memory is a later, optional swap**

- Skills: design-skill:memory.md §3 — typed memory (`posix_typed_mem_open`)
  is for "portable access to named physical pools/device memory", with
  `tflag` `POSIX_TYPED_MEM_ALLOCATE(_CONTIG)` / `MAP_ALLOCATABLE`, QNX OS
  path via `shm_open`+`shm_ctl(SHMCTL_TYMEM)`, and "Memory mapped from a
  typed-memory fd is implicitly locked". §4 — `shm_open`+`mmap(MAP_SHARED)`
  "is the **fastest IPC** (same physical pages) — you must synchronize".
- Project: README — "on QNX you can additionally use POSIX typed memory ...
  swap the `shm_open` in `qr_map` for that fd and nothing else changes".
- **Verdict: side with the project for the POC.** The slab has no physical
  contiguity, range, or DMA requirement, so `shm_open("/qnxml_demo")` under
  `/dev/shmem` is the documented default shared-memory IPC; the implicit-
  lock property of typed memory is moot in 8.0 (all memory wired, A.1).
  When a physical requirement appears (e.g. a DMA engine, below-4G for a
  peripheral), the skill's `posix_typed_mem_open` + `shm_ctl(SHMCTL_TYMEM)`
  path is the correct upgrade — but that is a milestone, not the POC. Note
  the skill's exact API (you cannot `open()` `/dev/tymem`; names are asinfo
  segments, tail-match/`&`/`|` syntax) differs from the README's casual
  "named physical region defined in your BSP's syspage" — worth tightening
  when that milestone lands.

### A.3 SPSC ring-per-peer vs QNX channel/pulse idiom — **compatible, but the control plane is missing; side with the skills on adding it**

- Skills: design-skill golden rule "Message, don't share. ... (or explicitly
  shared memory with your own synchronization)" — shared memory with your own
  sync is explicitly sanctioned. design-skill:architecture.md §4 — messages
  when you need a reply/back-pressure/bulk, **pulses** for "data ready",
  "Don't stream bulk data as many pulses". §2 — messages are copied
  directly sender→receiver address space (no intermediate buffer), so
  `MsgSendv` iovs at the slab are already zero-serialization.
- Project: README "SPSC discipline: one ring per direction per peer, which
  is also the natural shape for a QNX channel-per-service design".
- **Verdict: the ring is the right bulk path; the skills' idiom says the
  notification/control path should be pulses and messages, and the project
  has stubs for exactly that (`qr_channel_create`, `qr_connect_attach`,
  `qr_msg_send/receive/reply`) but no demo exercises them, and there is no
  pulse handling at all.** The current demo peers *poll* (`Unix.sleepf
  1e-4`) — the pattern the skills flag ("data ready" is a pulse; a channel
  receiver blocks in `MsgReceive` for free). The design direction (ring for
  zero-copy bulk + channel for deltas/control + pulse for notify) is the
  canonical QNX hybrid; the POC in §B makes it concrete.

### A.4 Priority inheritance — **message path gets it free; the ring path must be disciplined**

- Skills: design-skill:architecture.md §2 "Priority inheritance is built
  in: a blocked sender lends its priority to the receiver"; §3
  `_NTO_CHF_FIXED_PRIORITY` disables it (only with a reason);
  design-skill:processes-threads-scheduling.md §5 — mutexes default to
  `PTHREAD_PRIO_INHERIT`; unprivileged ceiling 63 without
  `PROCMGR_AID_PRIORITY`.
- Project: ring is lock-free (no mutexes), so no mutex-PI question; but a
  full-ring producer blocked in `MsgSendv` on the control channel *is* the
  inversion case the skills handle automatically. Conversely, a consumer
  polling an empty ring gets **no** boost — a medium-priority third process
  can starve it while the (high-priority) producer waits on a full ring.
- **Verdict: side with the skills.** Two concrete consequences for the POC:
  (1) the delta/control path must be real messages on a channel with
  inheritance enabled (default — do not set `_NTO_CHF_FIXED_PRIORITY`), so
  a blocked producer's priority propagates to the peer doing the work;
  (2) keep all peer priorities in 1–63 so the unprivileged `qnxuser`
  runtime needs no `PROCMGR_AID_PRIORITY` ability. Document the priority
  map (design-skill:processes-threads-scheduling.md DO-list).

### A.5 False sharing: Ring head/tail counters sit on the same cache line — **project bug, skills flag it**

- Skills: design-skill:multicore.md §4 "False sharing: keep per-CPU or
  per-thread hot data on separate cache lines; two threads writing adjacent
  variables on different cores can thrash the cache."
- Project: `ring.ml` layout — word 0 `tail` (producer-writes, release) and
  word 1 `head` (consumer-writes, release) are **adjacent int64s on one
  64-byte line**. On the Pi 5 with producer and consumer pinned to different
  cores (as the POC requires, A.9), every push/pop invalidates the other's
  line.
- **Verdict: side with the skills.** Pad `tail`/`head` onto separate cache
  lines in `Ring` (and keep hot words of `Vclock` per-peer counters
  separated likewise). Pure data-layout change; no semantics change; host
  tests stay green.

### A.6 `MAP_FIXED` "absolute cross-process references" — **overstated; costs an ability, buys nothing in the POC**

- Skills: design-skill:memory.md §2 — `MAP_FIXED` requires the
  `PROCMGR_AID_MAP_FIXED` ability (`mmap` → `EPERM` without it).
- Project: README "Fixed addressing: ... word indices are absolute
  cross-process references"; `region_stubs.c` `qr_map` sets `MAP_FIXED`
  when `~addr` is given.
- **Verdict: side with the skills on cost, and with the code on substance —
  the claim as written is wrong.** Word indices are *offsets within the
  mapping*; the library never dereferences a remote index as a virtual
  address, so identical placement is not required for correctness — each
  process's Bigarray base is local. `MAP_FIXED` therefore adds an ability
  requirement (`PROCMGR_AID_MAP_FIXED` for an unprivileged `qnxuser`
  process) and a collision risk (picking an address outside heap/stack/
  libs — the README's own caveat) without buying correctness. **Defer
  `MAP_FIXED` in the POC** (default `addr=0n`); revisit only if a later
  feature genuinely needs to dereference another process's absolute
  addresses (e.g. a debugger or a zero-copy hardware path).

### A.7 The channel stubs are incomplete: no pulse handling, no name discovery — **gap vs skills**

- Skills: design-skill:architecture.md §3 "DO prefer `name_attach()`/
  `name_open()` for stable service discovery over hard-coded (pid, chid)";
  §4 pulse semantics (`rcvid == 0`, never reply); golden rule "Check the
  `rcvid`."
- Project: `region_stubs.c` `qr_msg_receive` returns `rcvid` raw
  (`Val_long`); `qr_msg_reply` replies unconditionally. A pulse would
  arrive as `rcvid == 0` and the OCaml side has no way to distinguish or
  suppress the reply; there is no `name_attach` wrapper; `qr_connect_attach`
  needs the peer pid on the command line.
- **Verdict: side with the skills.** POC must (1) expose rcvid and teach the
  OCaml layer the `>0`/`==0`/`<0` contract, (2) use `_PULSE_CODE_MINAVAIL`
  range for any custom codes, (3) plan `name_attach`/`name_open` wrappers
  for service discovery rather than pid-on-argv (or accept pid-on-argv as a
  documented POC simplification, since `ChannelCreate`/`ConnectAttach` by
  pid is legal).

### A.8 Scheduling policy and multicore — **no policy/affinity anywhere today; skills require it for real-time claims**

- Skills: design-skill:processes-threads-scheduling.md §4 — explicit
  policies (FIFO/RR/SPORADIC), never `SCHED_OTHER` for real-time;
  design-skill:multicore.md §3 — "pinning every real-time thread to a core
  (BMP-style) is the reliable way to guarantee concurrency; do not assume
  SMP will spread N equal threads across N cores"; §2 — runmask must match a
  valid cluster (`EINVAL` otherwise).
- Project: demo peers run at default priority/policy, unpinned; nothing in
  the library touches scheduling.
- **Verdict: side with the skills.** For the POC, `SCHED_FIFO`, producer
  prio 30 / consumer prio 31 (≤63, unprivileged), producer pinned to CPU 0,
  consumer to CPU 1 (`ThreadCtl(_NTO_TCTL_RUNMASK, ...)`), verified against
  `pidin` cluster layout on the actual Pi 5 (4× A76; verify before coding —
  dev-skill "do not guess").

### A.9 Timing hygiene — **`Unix.gettimeofday` violates the skills' clock rule**

- Skills: design-skill golden rule "Measure with `CLOCK_MONOTONIC`, never
  `CLOCK_REALTIME` (it can jump)"; timing.md §5.
- Project: `demo/producer.ml` times the run with `Unix.gettimeofday ()`
  (REALTIME) and the peers sleep-poll with `Unix.sleepf` (up-to-a-tick
  oversleep, timing.md §4).
- **Verdict: side with the skills.** POC throughput must use
  `clock_gettime(CLOCK_MONOTONIC)` (new stub or `Unix.gettimeofday`-free
  wrapper); replace poll sleeps with pulse-blocking `MsgReceive` where the
  ring is the bulk path (A.3).

### A.10 Process creation — **`posix_spawn`, not fork; and spawn blocks until child init completes**

- Skills: design-skill golden rule "Prefer `posix_spawn()` over `fork()`";
  design-skill:processes-threads-scheduling.md §2 — fork from a threaded
  process can deadlock the child; spawn blocks until child init completes
  (lower-priority child delays parent).
- Project: demo processes are started by a shell (`demo` target in
  Makefile) — fine. A future launcher process must use `posix_spawn` with
  explicit priority/runmask at spawn
  (`POSIX_SPAWN_EXPLICIT_CPU` + `pthread_spawnattr_setrunmask_np`,
  multicore.md §2) and must not spawn a lower-priority child while holding
  anything the child needs.
- **Verdict: side with the skills; no current violation — record the rule
  for the POC launcher milestone.**

### A.11 Reuse before reinventing — **Merkle's mixer is fine for its stated scope; real integrity should use qcrypto**

- Skills: design-skill golden rule "Reuse before reinventing";
  api-navigation.md — QNX Cryptography Library (`qcrypto`) / `devcrypto`
  for crypto needs.
- Project: `merkle.ml` honestly scopes its mixer to corruption/divergence
  detection and names BLAKE3 as the swap-in.
- **Verdict: agree with the project's scoping; add qcrypto (not a
  hand-rolled BLAKE3 binding) as the roadmap answer if adversary resistance
  becomes a requirement.** No change needed for the POC.

### A.12 Build/deploy discipline — **project's scp dev-loop is the skill-sanctioned fastest loop; image integration must come later**

- Skills: dev-skill:development-workflow.md §4 — run loops, fastest first:
  NFS/debugger transfer, then copied file, then IFS rebuild; "Before
  release, always retest the exact packaged image"; dev-skill:bsp-and-
  images.md — "modified source must reach install/ before mkifs can select
  it"; verify staged vs imaged artifacts with `use -i`/`readelf` + hashes.
- Project: `CROSS.md` — "Copy producer.exe/consumer.exe to the Pi 5 target
  (scp/ftp to the running image)". The team's `example-qnx-project/Makefile`
  implements exactly the scp/ssh loop (`TARGET_IP ?= 192.168.208.80`,
  `TARGET_USER ?= qnxuser`, `DEST_DIR ?= /tmp`).
- **Verdict: agree — dev-loop is correct for iteration; but per
  dev-skill:project-governance.md "Definition of done", the POC milestone
  must end with the binaries staged into the CTI image via a snippet and
  boot-tested from the flashed `rpi5.img` (see §B.4).** Also flag: the
  stale GitHub snapshot at `/home/jm/data/qnx/qnx_custom_builds/QnXMl/`
  (old flat-file layout, no dune/demo) is a second source of truth and must
  be updated or removed before any CTI integration, or the wrong artifacts
  will be staged.

### A.13 Miscellaneous skill flags worth recording

- `_NTO_CHF_DISCONNECT` on `ChannelCreate` (already used in the stub) is
  correct — disconnect pulses detect client death (architecture.md §4).
- Validate incoming message lengths before touching buffers
  (architecture.md golden rule): the OCaml `MsgReceive` wrapper must bound-
  check `off+len` against `Region.dim` — currently it cannot.
- `/dev/shmem` is procnto's POSIX shm namespace; the CTI buildfile maps
  `/tmp` → `/dev/shmem` in the demo arrangement, which dev-skill:bsp-and-
  images.md warns is "not a fully featured substitute for production
  /tmp". The POC uses `/dev/shmem` for the slab (fine) but must not treat
  it as persistent storage.
- `memset(p, 0, 0)` in `qr_map` is a no-op remnant; harmless, delete when
  next touching the file.
- Design-skill:memory.md §2: `mmap_device_memory()` deprecated — not used,
  nothing to do; recorded for the DMA milestone.

---

## B. POC specification

Implementable from this section alone. Scope: prove the slab + ring +
delta-over-channel design on the real Pi 5 through the CTI toolchain, with
the fixes from §A that are marked POC-required.

### B.1 Target topology

| Process | Role | Policy / prio | CPU pin | IPC role |
|---|---|---|---|---|
| `qnxml_peer_a.exe` (from `demo/producer.ml`) | owns slab, produces | `SCHED_FIFO`, 30 | CPU 0 | server: `ChannelCreate(_NTO_CHF_DISCONNECT)` (inheritance ON), ring producer |
| `qnxml_peer_b.exe` (from `demo/consumer.ml`) | consumes | `SCHED_FIFO`, 31 | CPU 1 | client: `ConnectAttach(0, pid_a, chid, _NTO_SIDE_CHANNEL, 0)`, ring consumer |
| `qnxml_launch.exe` (new, small) | starts A and B | `SCHED_FIFO`, 32 | CPU 2 | uses `posix_spawn` + `POSIX_SPAWN_EXPLICIT_CPU` + runmask; passes pid/chid argv |

- Priorities 30–32 stay ≤ 63: unprivileged `qnxuser` needs no
  `PROCMGR_AID_PRIORITY` (design-skill:processes-threads-scheduling.md §4).
  Priority map documented in the demo README block.
- Runmask set via `ThreadCtl(_NTO_TCTL_RUNMASK, ...)`; verify the cluster
  exists first with `pidin syspage=cluster` on the actual board (A.8).
- Channels: one per peer for control (delta + ack); pulses (`MsgSendPulse`,
  code in `_PULSE_CODE_MINAVAIL..MAXAVAIL`) notify "ring became nonempty"
  so peer B blocks in `MsgReceive` instead of polling (A.3, A.7).
- Stub changes required (all additive, host stubs keep failing loudly):
  `qr_msg_receive` returns rcvid; add `qr_is_pulse` (rcvid==0) and
  `qr_msg_replyv`/`qr_msg_send_pulse`; `qr_msg_receive` gains a bound check
  against `Region.dim` (A.13).

### B.2 Slab setup: `/dev/shmem`, not typed memory — decision and rationale

- **Decision:** `shm_open("/qnxml_poc", O_CREAT)` + `ftruncate` + `mmap
  (MAP_SHARED)` — i.e. the existing `qr_map` path, `~addr` left 0.
- **Rationale:** no physical contiguity/range/DMA requirement exists (A.2);
  `shm_open` is the skill-documented fastest shared IPC and is what the
  code already does; typed memory's implicit-lock property is moot in 8.0
  (A.1); `MAP_FIXED` deferred (A.6). Revisit only if the DMA milestone
  requires `posix_typed_mem_open` + `shm_ctl(SHMCTL_TYMEM)`.
- Slab layout (extends `demo/layout.ml`; keep the carve order the
  cross-process contract and version it): word 0 magic, then layout-version
  word, then `Vclock` slice (padded per A.5), `Merkle` slice, `Ring` slice
  (head/tail padded to separate cache lines per A.5), `Pmap` arena slice,
  staging slice for outbound deltas (private staging for inbound, as the
  current producer comment already mandates).
- Pre-fault loop stays (this is the real "no runtime faults" guarantee,
  A.1); keep `mlock` call for Linux parity, log `locked`, never assert it.

### B.3 Demo flow on rpi5

1. Power the Pi 5 from the flashed CTI image; confirm `uname -a` shows QNX
   8.0 aarch64le; `pidin mem` to record RAM; `pidin syspage=cluster` to
   record the cluster layout.
2. `scp _build/qnx/demo/{producer,consumer,launch}.exe qnxuser@192.168.208.80:/tmp/`
3. `ssh qnxuser@192.168.208.80` then:
   - `./qnxml_launch.exe` (spawns A then B, waits, prints both pids)
   - or manually: `./consumer.exe &` then `./producer.exe 100000`
   - `ls /dev/shmem` while live → `qnxml_poc` present
   - `pidin` → both peers visible at prio 30/31, runmask pinned
4. Producer prints `N msgs in T s (X msg/s), checksum C`; consumer prints
   FIFO/checksum verdict; both exit 0.
5. Delta path: consumer sends its `Vclock` + pmap version + `Merkle` root
   via `MsgSendv` iov pointed at the slab; producer replies with a 1-word
   ack. Consumer prints the `Vclock.compare` verdict (Before/After/Equal)
   and the Merkle root match.

### B.4 Build + deploy flow via the CTI system

- **Dev loop (fastest valid, per dev-skill:development-workflow.md §4):**
  `source .envrc && make target` → `dune build -x qnx` → binaries under
  `_build/qnx/demo/`; deploy with the team's existing
  `example-qnx-project/Makefile` scp/ssh pattern (or `make run`
  equivalent) to `qnxuser@192.168.208.80:/tmp`. Iterate here.
- **Integration loop (required before calling the POC done, per
  dev-skill:project-governance.md DoD):**
  1. Update or delete the stale `/home/jm/data/qnx/qnx_custom_builds/QnXMl/`
     snapshot (A.12) so there is one source of truth.
  2. Stage the three `.exe`s and any needed shared libs under the CTI tree
     (e.g. a new `system_files.custom.qnxml` snippet placing them in
     `/usr/bin` — mirroring how `snippets/system_files.custom.*` work);
     add an `ifs_start`/slm snippet entry launching the demo (follow
     `targets/rpi5/snippets/` conventions; keep `slm.~20.custom.rootfs`
     pattern in mind).
  3. `cd /home/jm/data/qnx/qnx_custom_builds && make TARGET=rpi5` (sources
     `qnxsdp-env.sh` internally; per NEXT_STEP.md, apk steps need it
     sourced); result `build/rpi5/rpi5.img`.
  4. Prove the staged artifact is the imaged one: `use -i`/`ntoaarch64-readelf`
     on staged binary vs image contents, hash both
     (dev-skill:bsp-and-images.md).
  5. Flash with rpi-imager, cold-boot, run §B.5 acceptance from the flashed
     image (not scp'd binaries).
- Record in `CROSS.md`: exact env script path, `make TARGET=rpi5` command,
  image hash, and the `.QNX.command.line` of the imaged binaries.

### B.5 Acceptance tests (what proves success on the target)

1. **Identity:** `uname -a` → aarch64le QNX 8.0 on BCM2712; `pidin` shows
   both peers at expected priorities with expected runmasks.
2. **Slab/ring correctness:** consumer prints `N msgs, FIFO order ok,
   checksum ok`; producer prints matching count and checksum; both exit 0;
   `ls /dev/shmem` shows the object while live and it is gone after
   consumer unlinks.
3. **Delta/channel path:** consumer prints `Vclock` verdict
   (Before→applied), pmap version id increments, arena `nodes_in_use`
   stays under capacity, `Merkle.root` matches producer's; ack received.
4. **Zero steady-state allocation:** with `OCAMLRUNPARAM=s=256k`,
   `producer.exe 100000` completes; optional `slog2info` shows no faults;
   throughput printed from `CLOCK_MONOTONIC`.
5. **Repeatability:** run 3×; identical checksums and message counts;
   kill-and-restart producer mid-run does not wedge the consumer
   (disconnect pulse on `_NTO_CHF_DISCONNECT` observed).
6. **Packaged-image gate (DoD):** the same acceptance run passes from the
   flashed `rpi5.img` with the binaries baked in, not scp'd (A.12).
   Rollback condition: re-flash the previous known-good `rpi5.img`
   (preserved before the POC build, dev-skill:bsp-and-images.md baseline
   rule).

---

## C. Recommendations roadmap (ordered)

1. **Fix the docs' mlock claim** (README + `qr_lock` comment): mlock is a
   no-op portability shim on QNX 8.0; pre-faulting + all-wired memory is
   the guarantee. — *The single factually wrong claim facing reviewers.*
2. **Pad Ring head/tail (and Vclock peers) onto separate cache lines** —
   *fixes real false sharing once peers are pinned to different cores
   (A.5).*
3. **Add the channel/pulse control plane to the demo** (rcvid contract,
   `qr_is_pulse`, `MsgSendPulse`, `_NTO_CHF_DISCONNECT` already present) and
   replace `Unix.sleepf` polling with `MsgReceive` blocking — *this is the
   missing half of the QNX idiom (A.3, A.7) and the POC's core proof.*
4. **Switch throughput timing to `CLOCK_MONOTONIC`** — *skill golden rule
   (A.9); one-line change.*
5. **POC pinning: `SCHED_FIFO` 30/31/32 + runmasks CPU 0/1/2** — *only
   guaranteed concurrency on SMP (A.8); no abilities needed.*
6. **Defer `MAP_FIXED` (default `addr=0n`)** and drop the "absolute
   cross-process references" claim — *removes a `PROCMGR_AID_MAP_FIXED`
   ability requirement; indices are relative offsets (A.6).*
7. **Delete or refresh the stale CTI `QnXMl/` snapshot** before any image
   integration — *prevents staging wrong artifacts (A.12).*
8. **Integrate the POC into the CTI image** via a `system_files.custom.qnxml`
   snippet + startup entry, `make TARGET=rpi5`, flash, and pass §B.5 from
   the flashed image — *the dev-skill DoD "packaged image" gate.*
9. **Bound-check `MsgReceive` lengths against the region** — *skill's
   validate-every-message rule; currently impossible from OCaml (A.13).*
10. **Add `name_attach`/`name_open` wrappers** for peer discovery — *skill
    preference over pid-on-argv (A.7); small stub addition.*
11. **Defer:** typed-memory slab (`posix_typed_mem_open` +
    `shm_ctl(SHMCTL_TYMEM)`) — *only needed for physical/DMA constraints
    (A.2);* qcrypto-based integrity — *only if adversary resistance is
    required (A.11);* launcher hardening (`posix_spawn` attr, spawn-time
    runmask) — *needed only when the demo gains a launcher process (A.10).*

---

## D. Mandatory preflight blocks (filled for this project)

### D.1 Design preflight (qnx-os-and-application-design/SKILL.md)

```text
SDP release + environment script:
    QNX SDP 8.0 (CTI-staged) at /home/jm/data/qnx/qnx_custom_builds/qnx800;
    env: qnxsdp-env.sh (46 lines) or repo .envrc (sets QNX_HOST/QNX_TARGET,
    opam switch ocaml-base-compiler.5.3.0). Verified: qcc 12.2.0
    gcc_ntoaarch64le, target triple aarch64-unknown-nto-qnx8.0.0.

Target CPU, core count, endianness:
    Raspberry Pi 5, BCM2712, 4x Cortex-A76 (verify with pidin syspage),
    aarch64 little-endian.

Is this a process or a thread? Who creates/owns it?
    Processes. Peer A (producer) and peer B (consumer) are separate
    executables, launched by shell for the POC, later by a launcher via
    posix_spawn (A.10). Each process owns its threads; main thread only
    for the POC.

Scheduling policy + priority (and who is privileged to set it):
    SCHED_FIFO; A=30, B=31, launcher=32 (all <= 63, unprivileged — no
    PROCMGR_AID_PRIORITY needed). Set via pthread_setschedparam in-process
    (or spawn attributes in the launcher). qnxuser is not privileged.

IPC role: client or server? channel/connection or pathname? messages or pulses?
    Hybrid (A.3): shared-memory SPSC ring for bulk payload (own sync via
    acq/rel atomics — sanctioned by the skill's golden rule); server peer A
    owns a channel (ChannelCreate, _NTO_CHF_DISCONNECT, inheritance ON);
    peer B is client (ConnectAttach, _NTO_SIDE_CHANNEL). Messages
    (MsgSendv iov at slab) for deltas/acks; pulses for "ring nonempty"
    notification. rcvid contract (>0 reply, ==0 pulse never reply) to be
    enforced in the OCaml layer (A.7).

If a resource manager: pathname prefix, connect vs I/O handlers needed:
    Not a resource manager. No /dev pathname service. (name_attach deferred
    to roadmap item 10.)

If it touches hardware: IRQ number, trigger, shared?, IST priority:
    None. No hardware in the POC scope.

If it does DMA: is the SMMU active? which smmu object/permissions?
    N/A — no DMA. If the DMA milestone proceeds, revisit via
    design-skill:smmu-dma.md before writing code.

Timing constraints: deadline, period, required clock/timer, tolerance:
    No hard deadline in the POC. Throughput measured with CLOCK_MONOTONIC
    (A.9); poll sleeps replaced by pulse-blocking MsgReceive (A.3);
    default 1 ms tick is acceptable for the POC.

Memory: shared? device registers? contiguous/DMA? typed-memory pool?
    Shared: shm_open("/qnxml_poc") + mmap(MAP_SHARED), /dev/shmem
    namespace (B.2). No device registers, no contiguity/DMA requirement.
    Typed memory deliberately NOT used in the POC (A.2). MAP_FIXED
    deferred (A.6). Pre-fault at init; mlock kept for Linux parity only
    (A.1).
```

### D.2 Task preflight (qnx-project-development/SKILL.md)

```text
SDP release + environment script:
    QNX SDP 8.0; /home/jm/data/qnx/qnx_custom_builds/qnx800/qnxsdp-env.sh
    (CTI-installed SDP, the one qcc 12.2.0/gcc_ntoaarch64le resolves
    against). Repo builds also source /home/jm/data/qnx/QnXMl/.envrc
    (opam 5.3.0 + same SDP paths).

QNX_HOST / QNX_TARGET:
    QNX_HOST=/home/jm/data/qnx/qnx_custom_builds/qnx800/host/linux/x86_64
    QNX_TARGET=/home/jm/data/qnx/qnx_custom_builds/qnx800/target/qnx

Host OS:
    Debian trixie (Linux 7.1.3 x86_64), verified.

Target CPU and endianness:
    aarch64le (Raspberry Pi 5, BCM2712, 4x Cortex-A76).

Board, SoC, board revision, BSP package/revision:
    Raspberry Pi 5 (BCM2712); BSP = CTI rpi5 target
    (targets/rpi5/mkqnximage.config, OPT_TYPE=rpi5; msix-rp1-rework.patch
    applied); board revision to be read from the board at bring-up
    (do not guess).

Bootloader and transfer medium:
    Raspberry Pi bootloader (boot partition per CTI boot/, firmware tarball
    from raspberrypi/firmware); image transferred by flashing
    build/rpi5/rpi5.img to microSD (rpi-imager); dev iteration via scp/ssh
    to qnxuser@192.168.208.80 over cgem0 ethernet.

Buildfile/image target:
    build/rpi5/rpi5.img (mkqnximage, OPT_COPY_DEST=$BUILD/rpi5.img,
    OPT_HOSTNAME=qnxpi, OPT_SSH_IDENT=$BUILD/root_authorized_keys,
    OPT_SLM=yes). POC binaries to be added via a system_files.custom.qnxml
    snippet + startup entry (B.4).

Known-good image + recovery method:
    The pre-CTI-change rpi5.img snapshot preserved before the POC build
    (dev-skill:bsp-and-images.md baseline rule); recovery = re-flash that
    image to the microSD; serial console (/dev/ttyUSB1, 115200) as
    fallback per NOTES.md.

Acceptance test and rollback condition:
    Acceptance = B.5 items 1-6 (identity, ring/checksum correctness,
    channel delta + vclock/pmap/merkle verdicts, zero-alloc steady state,
    3x repeatability, packaged-image gate). Rollback = re-flash the
    preserved known-good image and confirm it boots to login (uname -a).
```

---

*This document changes no code. Where the skills and the project docs
disagree, this document sides with the skills and says so inline (A.1, A.3,
A.6, A.8, A.9); where the project's choices are already the skill-sanctioned
ones (A.2, A.11, A.12 dev-loop), it says so and records the boundary.*
