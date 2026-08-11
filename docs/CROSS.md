# Cross-compiling for QNX Neutrino (SDP 8.0, Raspberry Pi 5 / aarch64le)

The host build (`make host`) needs nothing but a normal opam switch. The
target build is a dune cross context named `qnx`, driven by a findlib
toolchain of the same name. Setting that toolchain up is a one-time job per
machine; the steps below are the intended path and the places where header
or configure fixes are expected to surface.

## 0. Prerequisites

- QNX SDP 8.0 installed and licensed; `. ~/qnx800/qnxsdp-env.sh` puts
  `qcc`/`ntoaarch64-*` on PATH and sets `QNX_HOST` / `QNX_TARGET`.
- An opam switch whose OCaml version you will mirror for the target
  (cross compiler and host compiler must be the same version).

## 1. Build an OCaml cross compiler with qcc

OCaml ≥ 5.2 (and 4.14 with the same flags) cross-compiles with a target
triplet + a C toolchain. QNX is not a blessed target, so expect to patch;
that is the "header fixes" part of this exercise.

```sh
tar xf ocaml-<version>.tar.gz && cd ocaml-<version>
./configure \
  --target=aarch64-unknown-nto-qnx8.0.0 \
  --prefix="$HOME/.opam/<switch>/qnx-sysroot" \
  CC="qcc -Vgcc_ntoaarch64le" \
  AR=ntoaarch64-ar RANLIB=ntoaarch64-ranlib \
  --disable-shared --disable-systhreads-tests
make crosscompiler   # falls back: make world.opt with OCAMLRUN from host
make install
```

Known friction points to look for (fix and record in this file as found):

- `sigaltstack` / `SA_SIGINFO` detection: Neutrino declares these in
  `<signal.h>` but configure's probe may need `-D_QNX_SOURCE`.
- `mmap` MAP_STACK is absent on QNX — the runtime guards this, but verify
  `HAS_STACK_OVERFLOW_DETECTION` came out unset.
- `nanosecond stat` fields differ (`st_mtim` vs `st_mtimespec`).
- linking: no `-lrt` (POSIX rt lives in libc), sockets need `-lsocket`.

## 2. Register the findlib "qnx" toolchain

findlib looks for `findlib.conf.d/qnx.conf` next to the switch's
`findlib.conf` (see `ocamlfind printconf conf`):

```
path(qnx)        = "<prefix>/qnx-sysroot/lib"
destdir(qnx)     = "<prefix>/qnx-sysroot/lib"
ocamlopt(qnx)    = "<prefix>/qnx-sysroot/bin/ocamlopt"
ocamlc(qnx)      = "<prefix>/qnx-sysroot/bin/ocamlc"
ocamlmklib(qnx)  = "<prefix>/qnx-sysroot/bin/ocamlmklib"
ocamldep(qnx)    = "ocamldep"
```

Check with `ocamlfind -toolchain qnx ocamlopt -config` — `system` should
report the QNX target, and that is also what flips the `-lrt` rule in
`lib/dune` off for the cross context.

## 3. Build and deploy

```sh
. ~/qnx800/qnxsdp-env.sh
dune build -x qnx            # or: make target
```

Binaries land in `_build/qnx/`. Copy `demo/producer.exe` and
`demo/consumer.exe` to the Pi 5 target (scp/ftp to the running image), then
on the target:

```sh
./consumer.exe &
./producer.exe 100000
ls /dev/shmem/              # qnxml_demo visible while the run is live
```

The demo is deliberately identical code host and target: shm_open, mmap,
mlock, and the acq/rel stubs are POSIX/gcc-builtin surface that Neutrino
provides natively. The QNX-only `MsgSendv` path in `region_stubs.c`
compiles only in this cross context (`__QNXNTO__`).

## Known friction points (lib/region_stubs.c vs. qcc/gcc_ntoaarch64le)
<!-- appended by stubs-compile worker; keep this section, append below -->

Verified against QNX SDP 8.0 (`qcc -Vgcc_ntoaarch64le`, aarch64le target)
with OCaml 5.3.0 headers (`opam exec --switch=ocaml-base-compiler.5.3.0 --
ocamlopt -where`). The compile only needs the `caml/*.h` headers, not
linkable OCaml objects, so the host switch's header dir is enough.

Reference command that succeeds:

```sh
. /home/jm/data/qnx/qnx_custom_builds/qnx800/qnxsdp-env.sh
qcc -Vgcc_ntoaarch64le -c lib/region_stubs.c \
  -I"$(opam exec --switch=ocaml-base-compiler.5.3.0 -- ocamlopt -where)" \
  -o /tmp/region_stubs_qnx.o
```

Findings:

- **No portability patches were required.** The file compiles cleanly on
  both qcc/QNX 8.0 and gcc/glibc as written. QNX 8's libc headers provide
  `MAP_ANONYMOUS`, `shm_open`/`shm_unlink`, `mlock`, `sysconf(_SC_PAGESIZE)`
  and GCC 12-based `__atomic_*` builtins, so no `#ifdef` beyond the existing
  `__QNXNTO__` fences was needed.
- The `__QNXNTO__` branch really is compiled on qcc: the object's undefined
  symbols include `MsgSendv`, `MsgReceive`, `MsgReply`
  (`ntoaarch64-nm -u /tmp/region_stubs_qnx.o`).
- `_GNU_SOURCE` is harmless under QNX headers (ignored) and still needed on
  glibc for `MAP_ANONYMOUS` under strict modes; left unconditional.
- One warning fixed for `-Wall -Wextra` hygiene: `qr_channel_create`'s
  unused `vunit` parameter now has an explicit `(void) vunit;` cast
  (qcc warned `-Wunused-parameter`; the host `#else` stubs already cast
  their params).
- Host check still passes:
  `gcc -c lib/region_stubs.c -I<same dir> -o /tmp/region_stubs_host.o`.
