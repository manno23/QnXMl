# Build verification — aarch64 QNX cross-compile (2026-08-11)

Status: **PASS** — the QnXMl library + demo cross-compile to genuine QNX
Neutrino 8.0 aarch64le binaries. On-device demo run is the remaining step
(Pi 5 not powered/reachable at commit time; see `deploy` below).

## Toolchain

- OCaml `5.5.1+dev0-2026-06-19` cross compiler for
  `aarch64-unknown-nto-qnx8.0.0`, built from mainline via
  `Makefile.cross` (`make crossopt`), installed under
  `~/.opam/default/qnx-sysroot`.
  Full recipe + required configure patches: `docs/CROSS.md` § "Native cross
  toolchain" (added by swarm a7).
- findlib toolchain `qnx` registered (path/destdir/ocamlc/ocamlopt/
  ocamlmklib/ocamldep → qnx-sysroot).
- Host OCaml 5.5.1 (opam switch `default`), dune 3.23.1. `source .envrc`
  for env (opam + QNX SDP 8.0, qcc, QNX_HOST/QNX_TARGET).

## Build

```sh
cd /home/jm/data/qnx/QnXMl
source .envrc
make target          # dune build -x qnx
```

Dune cross-context output lands in `_build/default.qnx/` (dune's actual
name for the `qnx` context; docs/INTEGRATION note `_build/qnx/` is the
documented alias and both are accepted by the staging Makefile).

## Artifacts (verified with `file`)

| artifact | result |
|---|---|
| `_build/default.qnx/demo/producer.exe` | ELF 64-bit LSB pie, ARM aarch64, interp `/usr/lib/ldqnx-64.so.2` |
| `_build/default.qnx/demo/consumer.exe` | same |
| `_build/default.qnx/test/test.exe` | same |
| `_build/default.qnx/lib/region_stubs.o` | ELF 64-bit LSB relocatable, ARM aarch64 |

Undefined symbols resolve against QNX `libc.so.6` / `libsocket.so.4`
(`ntoaarch64-nm -u`), i.e. a genuine Neutrino link, not a host-link.

## Non-fatal cosmetic warning

```
Warning: Dune was not able to automatically infer the C/C++ compiler in use: ""
```

Appears on `dune build -x qnx`; the build still produces correct aarch64
binaries (C compiler comes from `ocamlc(qnx) -config`: `c_compiler: qcc
-Vgcc_ntoaarch64le`). Not an error.

## Deploy to Pi 5 (device currently offline)

```sh
cd /home/jm/data/qnx/qnx_custom_builds/src/local/qnxml
make -f Makefile.deploy run        # scp + run producer/consumer on the Pi
```

- default TARGET_IP=192.168.208.80, user qnxuser, DEST_DIR=/tmp.
- The staging Makefile (CTI image path) hard-fails on non-aarch64 binaries
  by design; verified with `mkqnx6fsimg` that the rpi5 snippet bakes the
  binaries into the system partition at `/usr/bin/`.

## Evidence files

- This doc.
- `docs/CROSS.md` (recipe + patches + config results + verified section).
- CTI wiring: `/home/jm/data/qnx/qnx_custom_builds/src/local/qnxml/`
  (Makefile, Makefile.deploy, INTEGRATION.md) + rpi5 snippet
  `targets/rpi5/snippets/system_files.custom.qnxml`.
