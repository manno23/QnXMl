# qnx_ocaml — agent swarm configuration

This project is worked on by a small model swarm coordinated by a composer.
The composer owns decomposition, sequencing, and merge decisions; workers own
execution inside their lane. Nothing lands unless the green baseline holds.

## Composer

- **Model:** `claude-fable-5`
- **Role:** reads the task, splits it into lane-sized units, dispatches to the
  workers below, reviews their diffs against the invariants in this file, and
  is the only agent that merges. When a worker's result touches another lane
  (e.g. a stub signature change that ripples into OCaml externals), the
  composer re-dispatches the ripple rather than letting a worker cross lanes.

## Workers

### `glm-5.2` — systems implementation lane

Owns code that compiles: OCaml modules in `lib/`, the C stubs in
`lib/region_stubs.c`, dune files, the cross-compilation profile, and the
`demo/` executables. Typical dispatches:

- dune/build plumbing (host context and the `qnx` cross context)
- `__QNXNTO__`-fenced code: MsgSendv/MsgReceive/MsgReply wrappers, pulse
  handling, resource-manager glue
- performance work on the hot paths (ring push/pop, pmap set/find)

### `kimi-k3` — research & long-context lane

Owns work that is mostly reading: QNX SDP header spelunking (paste whole
headers into context — that is what this lane is for), Neutrino API semantics
(`shm_ctl`, `posix_typed_mem_open`, resmgr/dispatch layers), failure-log
analysis from target runs, and keeping `README.md` / `docs/` truthful against
the code. Typical dispatches:

- "why does this qcc compile fail" — given full header + error text
- documenting placement/determinism behavior actually observed on target
- test-plan design before glm-5.2 implements

## Swarm rules

1. **Green baseline is sacred.** `dune build && dune test` on the host must
   pass on every merge. QNX-only work happens behind `__QNXNTO__` or in the
   `qnx` cross context precisely so the host suite never breaks.
2. **One lane per dispatch.** A unit of work is one worker, one lane, one
   reviewable diff. The composer never asks a worker to "also fix" something
   in the other lane.
3. **Steady-state allocation is zero.** Any diff to `lib/` that introduces
   OCaml heap allocation on a hot path (closures, boxing, tuple returns) is
   rejected in composer review regardless of tests passing.
4. **Stubs are the whole OS surface.** New OS interaction goes in
   `region_stubs.c`, fenced for QNX where non-portable, with a loud host-side
   failure stub — never `Obj.magic`, never a second stubs file.
5. **Escalation.** If both workers disagree with the composer's review, or a
   change would alter a public interface in `lib/`, stop and surface to the
   human rather than merging.
