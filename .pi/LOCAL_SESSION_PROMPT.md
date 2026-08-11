# Prompt for the local (SDP-equipped) Claude Code session

Paste the block below when starting Claude Code on the machine that has the
QNX SDP. Fill in the two paths at the top first.

---

You are in a clone of manno23/qnxml, an OCaml library of preallocated
incremental-compute structures for QNX (see README.md). The host-side dune
project is already set up and green: `make host` builds the library, runs
the full test suite, and builds a two-process shm-ring demo; `make demo`
runs producer/consumer on this machine. Protect that baseline — every change
you make must keep `make host` passing.

My environment on this machine:

- QNX SDP 8.0 at: <PATH, e.g. ~/qnx_custom_builds/qnx800> — source
  qnxsdp-env.sh from there for qcc/QNX_TARGET. Licensed, targets Raspberry
  Pi 5 (aarch64le). My image tooling (mkqnximage, make_image.sh, targets/)
  lives in the same parent directory.
- opam is installed with existing switches: run `opam switch list` and pick
  or create an appropriate one rather than assuming the default.

Your task, in order, checking off each stage before the next:

1. **Sanity**: `make host` in this repo under my opam switch. Fix anything
   environment-specific but do not change library semantics.

2. **Compile the stubs against real Neutrino headers**: get
   `lib/region_stubs.c` compiling with
   `qcc -Vgcc_ntoaarch64le -c lib/region_stubs.c -I<ocaml runtime dir>`
   with `__QNXNTO__` active, so the MsgSendv/MsgReceive/MsgReply wrappers
   go through a real compiler for the first time. Record every header fix
   you need in docs/CROSS.md under "Known friction points".

3. **Cross toolchain**: follow docs/CROSS.md to build the OCaml cross
   compiler with qcc and register the findlib `qnx` toolchain, so
   `make target` (`dune build -x qnx`) produces aarch64 QNX binaries.
   Update CROSS.md wherever reality disagrees with it.

4. **Demo on target**: deploy `_build/qnx/demo/{producer,consumer}.exe` to
   the Pi 5 (or a QNX VM if the Pi isn't wired up), run the two-process
   demo over /dev/shmem, and paste the output back to me. If OCAMLRUNPARAM
   or mlock behaves differently on target than documented in README.md's
   determinism notes, correct the README.

5. Only after 1–4 are green: start the pulse-driven resource manager that
   wires Ring into a real dispatch loop (new `resmgr/` directory, QNX-only,
   must not disturb the host build).

Work on a branch, commit at each stage boundary, and stop to show me output
at the end of stages 2 and 4 before continuing.

---
