/* region_stubs.c — the entire OS-facing surface.
 *
 * Everything above this file is pure OCaml operating on one preallocated,
 * page-locked, optionally fixed-address memory region viewed as an int64
 * Bigarray. The Bigarray lives OUTSIDE the OCaml GC heap: the collector
 * never scans, moves, or frees it, which is what makes "allocate everything
 * up front, then never allocate" honest.
 *
 * Builds on QNX Neutrino (qcc) and on Linux/glibc for host-side testing.
 * QNX-only calls are fenced with __QNXNTO__.
 */

#define _GNU_SOURCE
#include <caml/mlvalues.h>
#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/fail.h>
#include <caml/bigarray.h>
#include <caml/threads.h>

#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <stdint.h>

#ifdef __QNXNTO__
#include <sys/neutrino.h>
#include <sys/mman.h>   /* shm_ctl */
#endif

/* ------------------------------------------------------------------ */
/* Region mapping                                                     */
/* ------------------------------------------------------------------ */

/* qr_map(name, words, create, addr) -> int64 bigarray
 *
 * name   = "" -> private anonymous mapping (single process)
 *          "/foo" -> POSIX shared object (cross-process; QNX: /dev/shmem/foo)
 * words  = size in 8-byte words, fixed for the life of the region
 * addr   = 0 -> kernel chooses placement; nonzero -> MAP_FIXED at that
 *          virtual address (identical layout in every process that maps it,
 *          so int64 indices are valid cross-process "pointers")
 */
CAMLprim value qr_map(value vname, value vwords, value vcreate, value vaddr)
{
    CAMLparam4(vname, vwords, vcreate, vaddr);
    size_t bytes = (size_t) Long_val(vwords) * 8;
    void *hint = (void *) Nativeint_val(vaddr);
    int flags = MAP_SHARED;
    int fd = -1;
    void *p;

    if (caml_string_length(vname) == 0) {
        flags = MAP_PRIVATE | MAP_ANONYMOUS;
    } else {
        int oflag = O_RDWR | (Bool_val(vcreate) ? O_CREAT : 0);
        fd = shm_open(String_val(vname), oflag, 0600);
        if (fd < 0) caml_failwith("qr_map: shm_open");
        if (Bool_val(vcreate) && ftruncate(fd, (off_t) bytes) != 0) {
            close(fd);
            caml_failwith("qr_map: ftruncate");
        }
    }
    if (hint != NULL) flags |= MAP_FIXED;

    p = mmap(hint, bytes, PROT_READ | PROT_WRITE, flags, fd, 0);
    if (fd >= 0) close(fd);
    if (p == MAP_FAILED) caml_failwith("qr_map: mmap");

    /* Touch every page now: all faults happen at init, none at runtime. */
    memset(p, 0, 0);  /* keep contents; pre-fault read/write below */
    {
        volatile char *c = (volatile char *) p;
        long pg = sysconf(_SC_PAGESIZE);
        size_t i;
        for (i = 0; i < bytes; i += (size_t) pg) c[i] = c[i];
    }

    CAMLreturn(caml_ba_alloc_dims(CAML_BA_INT64 | CAML_BA_C_LAYOUT,
                                  1, p, (intnat)(bytes / 8)));
}

/* Remove a named shared object (QNX: /dev/shmem/name). Idempotent: a
 * missing name is not an error, so teardown can be unconditional. */
CAMLprim value qr_unlink(value vname)
{
    if (caml_string_length(vname) > 0) shm_unlink(String_val(vname));
    return Val_unit;
}

/* Pin the region's pages: no paging at runtime. Returns whether it stuck
 * (needs privilege on Linux; on QNX, memory is not demand-paged to disk in
 * typical configs, but locking still prevents lazy mapping surprises). */
CAMLprim value qr_lock(value vba)
{
    void *p = Caml_ba_data_val(vba);
    size_t bytes = (size_t) Caml_ba_array_val(vba)->dim[0] * 8;
    return Val_bool(mlock(p, bytes) == 0);
}

CAMLprim value qr_base_addr(value vba)
{
    return caml_copy_nativeint((intnat) Caml_ba_data_val(vba));
}

/* ------------------------------------------------------------------ */
/* Acquire/release atomics on region words                            */
/* (the only fences the SPSC ring and version publication need)       */
/* ------------------------------------------------------------------ */

CAMLprim value qr_load_acq(value vba, value vidx)
{
    int64_t *a = (int64_t *) Caml_ba_data_val(vba);
    int64_t x = __atomic_load_n(&a[Long_val(vidx)], __ATOMIC_ACQUIRE);
    return caml_copy_int64(x);
}

CAMLprim value qr_store_rel(value vba, value vidx, value vx)
{
    int64_t *a = (int64_t *) Caml_ba_data_val(vba);
    __atomic_store_n(&a[Long_val(vidx)], Int64_val(vx), __ATOMIC_RELEASE);
    return Val_unit;
}

CAMLprim value qr_fetch_add(value vba, value vidx, value vx)
{
    int64_t *a = (int64_t *) Caml_ba_data_val(vba);
    int64_t x = __atomic_fetch_add(&a[Long_val(vidx)], Int64_val(vx),
                                   __ATOMIC_ACQ_REL);
    return caml_copy_int64(x);
}

/* ------------------------------------------------------------------ */
/* QNX IPC: the thinnest possible wrappers.                           */
/* Deltas travel as word-ranges of the region; MsgSendv points its    */
/* iov straight at the mapped memory — no serialization, no copy on   */
/* the OCaml side.                                                    */
/* ------------------------------------------------------------------ */

#ifdef __QNXNTO__

CAMLprim value qr_channel_create(value vunit)
{
    int chid = ChannelCreate(_NTO_CHF_DISCONNECT);
    if (chid < 0) caml_failwith("ChannelCreate");
    return Val_long(chid);
}

CAMLprim value qr_connect_attach(value vpid, value vchid)
{
    int coid = ConnectAttach(0, Long_val(vpid), Long_val(vchid),
                             _NTO_SIDE_CHANNEL, 0);
    if (coid < 0) caml_failwith("ConnectAttach");
    return Val_long(coid);
}

/* Send region words [off, off+len) as the message body; small reply into
 * a caller buffer of up to 8 words. Releases the OCaml runtime lock so
 * other domains/threads keep computing while we're SEND/REPLY-blocked. */
CAMLprim value qr_msg_send(value vcoid, value vba, value voff, value vlen)
{
    int64_t *a = (int64_t *) Caml_ba_data_val(vba);
    iov_t siov, riov;
    int64_t reply[8];
    int rc;
    SETIOV(&siov, a + Long_val(voff), (size_t) Long_val(vlen) * 8);
    SETIOV(&riov, reply, sizeof reply);
    caml_release_runtime_system();
    rc = MsgSendv(Long_val(vcoid), &siov, 1, &riov, 1);
    caml_acquire_runtime_system();
    if (rc < 0) caml_failwith("MsgSendv");
    return Val_long(rc);
}

CAMLprim value qr_msg_receive(value vchid, value vba, value voff, value vlen)
{
    int64_t *a = (int64_t *) Caml_ba_data_val(vba);
    int rcvid;
    caml_release_runtime_system();
    rcvid = MsgReceive(Long_val(vchid), a + Long_val(voff),
                       (size_t) Long_val(vlen) * 8, NULL);
    caml_acquire_runtime_system();
    if (rcvid < 0) caml_failwith("MsgReceive");
    return Val_long(rcvid);
}

CAMLprim value qr_msg_reply(value vrcvid, value vstatus)
{
    if (MsgReply(Long_val(vrcvid), Long_val(vstatus), NULL, 0) < 0)
        caml_failwith("MsgReply");
    return Val_unit;
}

#else /* host build: keep the symbols, fail loudly if called */

static value qnx_only(void) { caml_failwith("QNX-only IPC stub"); return Val_unit; }
CAMLprim value qr_channel_create(value a){ (void)a; return qnx_only(); }
CAMLprim value qr_connect_attach(value a, value b){ (void)a;(void)b; return qnx_only(); }
CAMLprim value qr_msg_send(value a, value b, value c, value d){ (void)a;(void)b;(void)c;(void)d; return qnx_only(); }
CAMLprim value qr_msg_receive(value a, value b, value c, value d){ (void)a;(void)b;(void)c;(void)d; return qnx_only(); }
CAMLprim value qr_msg_reply(value a, value b){ (void)a;(void)b; return qnx_only(); }

#endif
