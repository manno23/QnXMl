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
#include <stdio.h>
#include <time.h>

#ifdef __QNXNTO__
#include <sys/neutrino.h>
#include <sys/mman.h>   /* shm_ctl */
#include <pthread.h>
#include <sched.h>
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
/* Monotonic clock (SPEC A.9): throughput timing must never use       */
/* CLOCK_REALTIME, which can jump. CLOCK_MONOTONIC exists on QNX and  */
/* on Linux/glibc, so this single implementation serves both the      */
/* target and the host (the host fallback is the same call — no       */
/* QNX-only guard needed). Returns whole nanoseconds since an         */
/* arbitrary origin.                                                  */
/* ------------------------------------------------------------------ */

CAMLprim value qr_monotonic_ns(value vunit)
{
    struct timespec ts;
    (void) vunit;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0)
        caml_failwith("clock_gettime(CLOCK_MONOTONIC)");
    return caml_copy_int64(((int64_t) ts.tv_sec * 1000000000LL) + ts.tv_nsec);
}

/* rcvid == 0 <=> pulse. The whole pulse contract hangs off this one
 * predicate: >0 = message (must reply), ==0 = pulse (never reply),
 * <0 = error (-errno, do not reply). Pure integer test, no OS calls. */
CAMLprim value qr_is_pulse(value vrcvid)
{
    return Val_bool(Long_val(vrcvid) == 0);
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
    (void) vunit;
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
    CAMLparam4(vcoid, vba, voff, vlen);
    int64_t *a = (int64_t *) Caml_ba_data_val(vba);
    intnat dim = Caml_ba_array_val(vba)->dim[0];
    intnat off = Long_val(voff), len = Long_val(vlen);
    iov_t siov, riov;
    int64_t reply[8];
    int rc;
    if (off < 0 || len < 0 || off > dim || len > dim - off)
        caml_failwith("qr_msg_send: range outside region");
    SETIOV(&siov, a + off, (size_t) len * 8);
    SETIOV(&riov, reply, sizeof reply);
    caml_release_runtime_system();
    rc = MsgSendv(Long_val(vcoid), &siov, 1, &riov, 1);
    caml_acquire_runtime_system();
    if (rc < 0) caml_failwith("MsgSendv");
    CAMLreturn(Val_long(rc));
}

/* Blocking receive (SPEC A.3, A.7): returns (rcvid, nbytes) so the OCaml
 * layer applies the full contract — rcvid > 0 must-reply, == 0 pulse
 * never-reply, < 0 error — and validates the received length before
 * trusting the payload (the skill's validate-every-message rule).
 * The destination range is bound-checked against the region BEFORE the
 * kernel can copy anything into it. */
CAMLprim value qr_msg_receive(value vchid, value vba, value voff, value vlen)
{
    CAMLparam4(vchid, vba, voff, vlen);
    CAMLlocal1(res);
    int64_t *a = (int64_t *) Caml_ba_data_val(vba);
    intnat dim = Caml_ba_array_val(vba)->dim[0];
    intnat off = Long_val(voff), len = Long_val(vlen);
    struct _msg_info info;
    int rcvid;
    if (off < 0 || len < 0 || off > dim || len > dim - off)
        caml_failwith("qr_msg_receive: range outside region");
    caml_release_runtime_system();
    rcvid = MsgReceive(Long_val(vchid), a + off, (size_t) len * 8, &info);
    caml_acquire_runtime_system();
    res = caml_alloc_tuple(2);
    Store_field(res, 0, Val_long(rcvid));
    Store_field(res, 1, Val_int(rcvid < 0 ? 0 : (intnat) info.msglen));
    CAMLreturn(res);
}

CAMLprim value qr_msg_reply(value vrcvid, value vstatus)
{
    if (MsgReply(Long_val(vrcvid), Long_val(vstatus), NULL, 0) < 0)
        caml_failwith("MsgReply");
    return Val_unit;
}

/* Reply with region words [off, off+len) as the body (a 1-word ack for
 * the delta handshake). rcvid here is always > 0 — replying to a pulse
 * is a contract violation and the OCaml layer must never route one here. */
CAMLprim value qr_msg_replyv(value vrcvid, value vstatus, value vba,
                             value voff, value vlen)
{
    CAMLparam5(vrcvid, vstatus, vba, voff, vlen);
    int64_t *a = (int64_t *) Caml_ba_data_val(vba);
    intnat dim = Caml_ba_array_val(vba)->dim[0];
    intnat off = Long_val(voff), len = Long_val(vlen);
    iov_t riov;
    int rc;
    if (off < 0 || len < 0 || off > dim || len > dim - off)
        caml_failwith("qr_msg_replyv: range outside region");
    SETIOV(&riov, a + off, (size_t) len * 8);
    caml_release_runtime_system();
    rc = MsgReplyv(Long_val(vrcvid), Long_val(vstatus), &riov, 1);
    caml_acquire_runtime_system();
    if (rc < 0) caml_failwith("MsgReplyv");
    CAMLreturn(Val_unit);
}

/* Fire-and-forget notification (SPEC A.3): code must be in the
 * _PULSE_CODE_MINAVAIL..MAXAVAIL range (the demo Layout pins it there);
 * priority -1 = inherit the sender's. Never blocks; EAGAIN only if the
 * pulse pool is exhausted. */
CAMLprim value qr_msg_send_pulse(value vcoid, value vcode, value vvalue)
{
    CAMLparam3(vcoid, vcode, vvalue);
    int rc;
    caml_release_runtime_system();
    rc = MsgSendPulse(Long_val(vcoid), -1, Int_val(vcode),
                      (long) Int64_val(vvalue));
    caml_acquire_runtime_system();
    if (rc < 0) caml_failwith("MsgSendPulse");
    CAMLreturn(Val_unit);
}

/* Real-time posture (SPEC B.1): SCHED_FIFO at the given priority and a
 * BMP-style single-CPU runmask. Priorities 30/31 stay <= 63 so the
 * unprivileged qnxuser needs no PROCMGR_AID_PRIORITY. The runmask must
 * match a cluster defined by the startup program (verify with
 * `pidin syspage=cluster`); a singleton {cpu} is a valid cluster on the
 * rpi5 default layout. */
CAMLprim value qr_sched_fifo(value vprio)
{
    struct sched_param p;
    memset(&p, 0, sizeof p);
    p.sched_priority = Int_val(vprio);
    if (pthread_setschedparam(pthread_self(), SCHED_FIFO, &p) != 0)
        caml_failwith("pthread_setschedparam(SCHED_FIFO)");
    return Val_unit;
}

CAMLprim value qr_set_runmask(value vcpu)
{
    /* The runmask VALUE is passed as the data pointer (uint64 -> void*). */
    uintptr_t mask = (uintptr_t) 1 << Long_val(vcpu);
    if (ThreadCtl(_NTO_TCTL_RUNMASK, (void *) mask) != 0)
        caml_failwith("ThreadCtl(_NTO_TCTL_RUNMASK)");
    return Val_unit;
}

#else /* host build: keep the symbols, fail loudly if called */

static value qnx_only(void) { caml_failwith("QNX-only IPC stub"); return Val_unit; }
CAMLprim value qr_channel_create(value a){ (void)a; return qnx_only(); }
CAMLprim value qr_connect_attach(value a, value b){ (void)a;(void)b; return qnx_only(); }
CAMLprim value qr_msg_send(value a, value b, value c, value d){ (void)a;(void)b;(void)c;(void)d; return qnx_only(); }
CAMLprim value qr_msg_receive(value a, value b, value c, value d){ (void)a;(void)b;(void)c;(void)d; return qnx_only(); }
CAMLprim value qr_msg_reply(value a, value b){ (void)a;(void)b; return qnx_only(); }
CAMLprim value qr_msg_replyv(value a, value b, value c, value d, value e){ (void)a;(void)b;(void)c;(void)d;(void)e; return qnx_only(); }
CAMLprim value qr_msg_send_pulse(value a, value b, value c){ (void)a;(void)b;(void)c; return qnx_only(); }

/* Scheduling/pinning: QNX-only, no-op with a log line on the host so the
 * demo keeps working under `make demo`. */
static void qnx_noop(const char *what)
{
    fprintf(stderr, "host: %s is QNX-only; no-op on this build\n", what);
}

CAMLprim value qr_sched_fifo(value vprio)
{
    (void) vprio;
    qnx_noop("SCHED_FIFO priority");
    return Val_unit;
}

CAMLprim value qr_set_runmask(value vcpu)
{
    (void) vcpu;
    qnx_noop("CPU runmask pinning");
    return Val_unit;
}

#endif
