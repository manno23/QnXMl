# LMDB on QNX 8.0 (aarch64le) — verified build

Proven: `vendor/lmdb/libraries/liblmdb` cross-compiles for
`aarch64-unknown-nto-qnx8.0.0` with:

    source /home/jm/data/qnx/QnXMl/.envrc
    make -C vendor/lmdb/libraries/liblmdb clean
    make -C vendor/lmdb/libraries/liblmdb \
      CC="qcc -Vgcc_ntoaarch64le" AR="ntoaarch64-ar" \
      XCFLAGS="-O2" liblmdb.a

- `liblmdb.a` built: 3 members (mdb.o, midl.o, module.o), ELF aarch64 relocatable.
- Shared lib `liblmdb.so` FAILS: the Makefile links `-ldl`, which QNX does not
  have (dlopen lives in libc). Build the static lib only (as above), or patch
  the Makefile to drop `-ldl` for QNX.
- Undefined symbols in mdb.o are exactly the QNX libc surface: mmap/munmap/msync,
  ftruncate, fdatasync, fcntl, pread, pthread_* (mutex/cond/key), stdio, malloc.
  No glibc-only or -ldl deps. Linkable.
- `-pthread` warning from qcc is harmless (ignored on QNX).
- Host build (`make` with gcc) also works for host-side tests.

Open questions (for the store spec, docs/IMPL-STORE.md):
- Which writable filesystem hosts the LMDB env on the target (QNX IFS is
  read-only; need /data partition, devf-ram, or flash fs).
- Durability flags (MDB_NOSYNC etc.) vs spec TXN-004 "single fsync point".
- LMDB lock file requires a real filesystem (not /dev/shmem).
