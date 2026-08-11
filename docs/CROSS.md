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

## Native cross toolchain: OCaml 5.5.1+dev0-2026-06-19 (Makefile.cross), 2026-08-11
<!-- appended by cross-compiler worker; append-only -->

Status: **native cross build works end to end** on QNX SDP 8.0 (aarch64le),
using the upstream `Makefile.cross` / `make crossopt` model — no backport
needed. The host compiler is the opam `default` switch
(`ocaml-variants.5.5.1+trunk`, version string `5.5.1+dev0-2026-06-19`, exec
magic `Caml1999X037`), and the tree is the **5.5 branch** (not trunk!) at the
matching date: commit `dcc1c6aec` (2026-06-19), whose `build-aux/ocaml_version.m4`
reads `5.5.1+dev0-2026-06-19` (trunk on that date already read 5.6.0+dev).

### Recipe that worked

```sh
# 1. tree: ocaml 5.5 branch @ dcc1c6aec (or any commit whose version string
#    matches the host compiler; configure checks it: "checking if the
#    installed OCaml compiler can build the cross compiler... yes")
git clone https://github.com/ocaml/ocaml /tmp/ocaml551
git -C /tmp/ocaml551 checkout -B qnx-build dcc1c6aec37bd26917a42aef457b194abcdbab79

# 2. configure (in-tree). NOTE the PTHREAD_CFLAGS env var: see patches below.
./configure --target=aarch64-unknown-nto-qnx8.0.0 \
  --prefix=$HOME/.opam/default/qnx-sysroot \
  CC="qcc -Vgcc_ntoaarch64le" AR=ntoaarch64-ar RANLIB=ntoaarch64-ranlib \
  --disable-shared --disable-dependency-generation \
  TARGET_BINDIR=/usr/bin TARGET_LIBDIR=/usr/lib/ocaml \
  PTHREAD_CFLAGS=-D_REENTRANT

# 3. build + install
make -j8 crossopt          # see "make crossopt parent dies" caveat below
make installcross          # NOT plain `make install`: installcross adds the
                           # overrides (OCAMLRUN=ocamlrun, build_ocamldoc=false,
                           # WITH_DEBUGGER=) that make install sane for cross.
```

### Patches required (all against the generated ./configure, not the repo)

| file | change | why |
|------|--------|-----|
| `configure` | add `aarch64-*-nto-qnx*` case in the native-backend AS_CASE: `has_native_backend=yes; arch=arm64; system=ntoqnx8` (also add `natdynlink=true` in the natdynlink AS_CASE) | upstream only blesses aarch64-linux/freebsd/openbsd/netbsd/darwin; without this `NATIVE_COMPILER=false` and you get a bytecode-only toolchain |
| `configure` | add a QNX case in the sockets AS_CASE: `cclibs="$cclibs -lsocket"; LIBS="-lsocket $LIBS"` | Neutrino keeps sockets in libsocket, not libc; without it `HAS_SOCKETS` is unset and Unix.socket etc. are dead |
| `configure` env | pass `PTHREAD_CFLAGS=-D_REENTRANT` at configure time | AX_PTHREAD keys off $host_os (linux) and #errors unless `_REENTRANT` is defined; qcc *ignores* `-pthread` ("unnecessary for qnx") and never defines `_REENTRANT`. The env-var path makes AX_PTHREAD use a plain `pthread_join` link test. Semantically harmless: QNX is always-threaded |
| `Makefile.config` (generated) | `CPP=qcc -Vgcc_ntoaarch64le -E -P` → drop `-P` | qcc's driver silently produces **empty output** for `-E -P`. The `-P`-stripped output carries `# 1 "..."` line markers, which OCaml's lexer accepts (the tree's own `emit.ml` starts with one). Only affects generated `utils/domainstate.ml{,i}` (and Windows-only `domain_state.inc`) |

Also: `--disable-dependency-generation` is required — qcc's driver does not
understand gcc's `-MMD/-MT/-MF` and errors with "Can't specify -P, -C, -E, -c
or -S with -o and have multiple files" (it treats the `-MT`/`-MF` argument as
a second input file).

### Config results worth knowing (QNX quirks)

- `SYSTEM=ntoqnx8`, `ARCH=arm64`, `NATIVE_COMPILER=true`. `system` only feeds
  codegen flags: `arm64/arch.ml`'s `top_bits_ignore = (system = "linux")`
  → false for QNX (correct: no TBI on Neutrino), and `compilenv.ml` uses
  ELF-style symbol mangling for anything non-Darwin/MinGW (correct).
- `BYTECCLIBS/NATIVECCLIBS` end with `-lsocket -lm` — every linked executable
  gets `-lsocket` (matches `lib/dune`'s `case %{system}` which already emitted
  `()` for non-linux).
- No `-lrt` anywhere (rt lives in libc on Neutrino). `HAS_STACK_OVERFLOW_DETECTION`
  unset (no MAP_STACK) — "checking whether mmap supports MAP_STACK... no assumed".
  `st_atim.tv_nsec` probe found yes, so no stat-nanosecond patch.
- zstd on the target is too old (<1.4) → compressed compilation artefacts off
  (fine). `ocamldebug supported` (unix lib builds).

### make crossopt caveat: parent make dies silently at the very last step

Twice (once resuming a partial tree, once from a `make clean` state) the
top-level `make crossopt` process disappeared **with no error** at the
transition from the `tools-allopt.opt` sub-make to the final
CROSSCOMPILERLIBS recipe (log ends at `make[1]: Leaving directory`, no
`rm -f` echo, no "Error N"). No OOM evidence in dmesg (unprivileged); exit
status unrecoverable (process gone). The final recipe itself is healthy:

```sh
# run manually if crossopt's parent dies; it rebuilds compiler-libs for target
cd /tmp/ocaml551
source .envrc
make -n crossopt > /tmp/dry.txt        # lines 121-124 = the final recipe
sed -n '121,123p' /tmp/dry.txt | bash  # rm -f <all compiler .cmx> + cmxa
sed -n '124p'      /tmp/dry.txt | bash # make compilerlibs/*.cmxa CAMLC=ocamlc CAMLOPT="./ocamlopt.opt -nostdlib -I ./stdlib"
```

Do **not** re-run `make crossopt` after the final step: it is not idempotent —
the earlier `ocamlc.opt ocamlopt.opt` step re-links host binaries against the
now-aarch64 `compilerlibs/*.a` and fails with `Relocations in generic ELF
(EM: 183)` / `file in wrong format` (and the failed link deletes the working
`ocamlc.opt`/`ocamlopt.opt`). The correct end state after the final step is:
aarch64 `compilerlibs/*.cmxa/.a`, host x86-64 `ocamlc.opt`/`ocamlopt.opt`.

### findlib toolchain (default switch)

`$HOME/.opam/default/lib/findlib.conf.d/qnx.conf`:

```
path(qnx)        = "/home/jm/.opam/default/qnx-sysroot/lib/ocaml"
destdir(qnx)     = "/home/jm/.opam/default/qnx-sysroot/lib/ocaml"
ocamlc(qnx)      = "/home/jm/.opam/default/qnx-sysroot/bin/ocamlc"
ocamlopt(qnx)    = "/home/jm/.opam/default/qnx-sysroot/bin/ocamlopt"
ocamlmklib(qnx)  = "/home/jm/.opam/default/qnx-sysroot/bin/ocamlmklib"
ocamldep(qnx)    = "ocamldep"
ocamldoc(qnx)    = "ocamldoc"
```

`ocamlfind -toolchain qnx ocamlopt -config` → `architecture: arm64`,
`system: ntoqnx8`, `standard_library: /home/jm/.opam/default/qnx-sysroot/lib/ocaml`.

### Verified end-to-end

- `make host` green (dune build + dune test).
- `make target` (`dune build -x qnx`) green, idempotent.
- `file _build/default.qnx/demo/producer.exe` →
  `ELF 64-bit LSB pie executable, ARM aarch64 ... interpreter /usr/lib/ldqnx-64.so.2`.
- `ntoaarch64-nm` on producer.exe: `U shm_open`, `U mlock`, `U mmap`
  (libc), `U MsgSendv` (the `__QNXNTO__` IPC path in lib/region_stubs.c is
  really compiled in). `ntoaarch64-objdump -p` NEEDED: `libsocket.so.4`,
  `libm.so.3`, `libc.so.6`, `libgcc_s.so.1`.
- Bytecode side also installs: `bin/aarch64-unknown-nto-qnx-ocamlrun-b106`
  is aarch64 ELF; `ocamlc` bytecode programs get
  `#!/usr/bin/ocamlrun-b106` launcher (TARGET_BINDIR=/usr/bin), so on the Pi
  copy the ocamlrun binary to `/usr/bin/ocamlrun-b106` for bytecode-only use.
