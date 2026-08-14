# Native OCaml cross-compilation for QNX OS 8.0

We built an OCaml 5.5 native cross-compiler targeting **QNX OS 8.0 on
AArch64** using OCaml's upstream `Makefile.cross` and `crossopt` mechanism.
The host and target compilers use the same OCaml revision, while QNX
`qcc -Vgcc_ntoaarch64le`, `ntoaarch64-ar`, and `ntoaarch64-ranlib` provide
the target C toolchain. The resulting compiler is installed in a separate
QNX sysroot and registered as a findlib/Dune toolchain. Applications can
then be cross-built with:

```sh
source .envrc
dune build -x qnx
```

The resulting programs have been verified as genuine 64-bit AArch64 QNX
PIE executables using `/usr/lib/ldqnx-64.so.2`. Their object format and
library dependencies have been inspected successfully. Execution on the
physical Raspberry Pi 5 was still outstanding in the recorded build
verification.

## Challenges and fixes

QNX is not currently a standard upstream OCaml target, so the build needed
several configuration adjustments:

- OCaml's configure logic was extended to recognize
  `aarch64-*-nto-qnx*`, select the ARM64 native backend, and identify the
  target system as `ntoqnx8`.
- QNX socket APIs reside in `libsocket`, so `-lsocket` was added to enable
  the OCaml `Unix.socket` APIs.
- QNX is inherently threaded, but `qcc` ignores `-pthread` and does not
  define `_REENTRANT`. Supplying `PTHREAD_CFLAGS=-D_REENTRANT` allowed the
  pthread feature tests to succeed.
- `qcc -E -P` silently produced empty preprocessor output. Removing `-P`
  fixed generation of OCaml runtime source files.
- QNX `qcc` did not accept the GCC dependency-generation combination used
  by the OCaml build, so dependency generation was disabled.
- QNX has no `MAP_STACK`, so OCaml's corresponding stack-overflow detection
  facility remained disabled. QNX also provides POSIX real-time functions
  in libc, so the build must not add `-lrt`.
- The final `crossopt` compiler-library step occasionally had to be invoked
  manually, and the completed build tree was not safely reusable for a
  second complete `crossopt` run.

The complete reproducible recipe and exact patches are recorded in
[`docs/CROSS.md`](CROSS.md); artifact inspection is recorded in
[`docs/BUILD-VERIFIED.md`](BUILD-VERIFIED.md).

## QNX APIs available to OCaml

The cross-compiled OCaml runtime and `Unix` library provide much of the
normal POSIX surface, including files, descriptors, clocks, memory mapping,
threads, and sockets. Verified programs currently link against QNX
`libc.so.6`, `libsocket.so.4`, `libm.so.3`, and `libgcc_s.so.1`.

QNX-specific microkernel services are made available through small OCaml C
bindings. This project currently binds:

- POSIX shared memory, `mmap`, `mlock`, and `CLOCK_MONOTONIC`;
- acquire/release and fetch-add atomic operations;
- `ChannelCreate` and `ConnectAttach`;
- `MsgSendv`, `MsgReceive`, `MsgReply`, and `MsgReplyv`;
- `MsgSendPulse`;
- FIFO scheduling and `ThreadCtl` CPU runmasks.

The linked binaries retain QNX symbols such as `MsgSendv`, confirming that
the QNX-specific path is compiled and resolved against Neutrino rather than
a host substitute.

Nearly any C-callable QNX service can be exposed in the same way, but it is
not automatically part of OCaml's standard library. Each additional API
needs a binding that handles OCaml value conversion and GC rooting, releases
the OCaml runtime around appropriate blocking calls, translates QNX errors,
and links the required QNX library. Resource-manager, interrupt, typed-memory,
DMA/SMMU, and cryptography APIs therefore remain available in principle but
must be bound explicitly as the application requires them.
