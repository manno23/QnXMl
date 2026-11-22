/* region_stubs.c — the entire OS-facing surface.
 *
 * Everything above this file is pure OCaml operating on one preallocated,
 * page-locked, optionally fixed-address memory region viewed as an int64
 * Bigarray. The Bigarray lives OUTSIDE the OCaml GC heap: the collector
 * never scans, moves, or frees it.
 *
 * Steady-state hot paths must not allocate. Counters that fit in a 63-bit
 * OCaml int cross the FFI as tagged integers (no caml_copy_int64). Payload
 * copies and the Merkle mixer run in C so an int64 Bigarray access never
 * boxes. QNX IPC returns a negative errno instead of raising, so EAGAIN
 * under backpressure is a value the caller can coalesce on.
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
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <time.h>
#include <signal.h>
#include <pthread.h>
#include <sys/file.h>

#ifdef __QNXNTO__
#include <sys/neutrino.h>
#include <pthread.h>
#include <sched.h>
#endif

/* Error codes returned as the first field of qr_map / qr_reclaim.
   Keep in sync with Region.decode in region.ml. */
enum {
    QR_OK = 0,
    QR_ERR_SHM_OPEN = 1,
    QR_ERR_TRUNCATE = 2,
    QR_ERR_MMAP = 3,
    QR_ERR_TOO_SMALL = 4,
    QR_ERR_SIZE = 5,
    QR_ERR_EXISTS = 6,
    QR_ERR_STAT = 7,
    QR_ERR_INUSE = 8,
    QR_ERR_RANGE = 9,
    QR_ERR_NOT_FOUND = 10,
    QR_ERR_FIXED = 11
};

static int64_t qr_dummy_word;

static int words_to_bytes(intnat words, size_t *out)
{
    if (words <= 0) return QR_ERR_RANGE;
    if ((uintnat)words > (SIZE_MAX / 8)) return QR_ERR_RANGE;
    *out = (size_t)words * 8;
    return QR_OK;
}

static value map_result(int err, value ba)
{
    CAMLparam1(ba);
    CAMLlocal1(res);
    res = caml_alloc_tuple(2);
    Store_field(res, 0, Val_int(err));
    Store_field(res, 1, ba);
    CAMLreturn(res);
}

static value map_error(int err)
{
    value ba = caml_ba_alloc_dims(CAML_BA_INT64 | CAML_BA_C_LAYOUT,
                                  1, &qr_dummy_word, (intnat)1);
    return map_result(err, ba);
}

/* Touch every page now: faults happen at init, not at runtime.
   The mapping is exactly [bytes] long; never walk past it (W1). */
static void prefault(void *p, size_t bytes)
{
    volatile char *c = (volatile char *)p;
    long pg = sysconf(_SC_PAGESIZE);
    size_t i;
    if (pg <= 0) pg = 4096;
    for (i = 0; i < bytes; i += (size_t)pg) c[i] = c[i];
    if (bytes > 0) c[bytes - 1] = c[bytes - 1];
}

static value finish_map(void *p, size_t bytes)
{
    prefault(p, bytes);
    value ba = caml_ba_alloc_dims(CAML_BA_INT64 | CAML_BA_C_LAYOUT,
                                  1, p, (intnat)(bytes / 8));
    return map_result(QR_OK, ba);
}

/* qr_map(name, words, create, addr) -> (code, bigarray)
 *
 * name  = ""     private anonymous mapping (single process)
 *       = "/foo" POSIX shared object. create=true is O_CREAT|O_EXCL:
 *                an existing object is left untouched (QR_ERR_EXISTS),
 *                never ftruncated. create=false fstats and refuses with
 *                QR_ERR_TOO_SMALL when st_size < the requested bytes,
 *                so a short object is an error instead of a SIGBUS.
 * addr  nonzero requests MAP_FIXED_NOREPLACE. Where that flag does not
 *       exist the hint is rejected (QR_ERR_FIXED) rather than silently
 *       replacing whatever was mapped there.
 */
CAMLprim value qr_map(value vname, value vwords, value vcreate, value vaddr)
{
    CAMLparam4(vname, vwords, vcreate, vaddr);
    size_t bytes = 0;
    int err = words_to_bytes(Long_val(vwords), &bytes);
    void *hint = (void *)Nativeint_val(vaddr);
    int creating = Bool_val(vcreate);
    int flags = MAP_SHARED;
    int fd = -1;
    int created = 0;
    void *p = NULL;
    const char *name = NULL;

    if (err != QR_OK) CAMLreturn(map_error(err));

    if (hint != NULL) {
#ifdef MAP_FIXED_NOREPLACE
        flags |= MAP_FIXED_NOREPLACE;
#else
        CAMLreturn(map_error(QR_ERR_FIXED));
#endif
    }

    if (caml_string_length(vname) == 0) {
        flags = MAP_PRIVATE | MAP_ANONYMOUS;
        if (hint != NULL) {
#ifdef MAP_FIXED_NOREPLACE
            flags |= MAP_FIXED_NOREPLACE;
#endif
        }
        p = mmap(hint, bytes, PROT_READ | PROT_WRITE, flags, -1, 0);
        if (p == MAP_FAILED) CAMLreturn(map_error(QR_ERR_MMAP));
        CAMLreturn(finish_map(p, bytes));
    }

    name = String_val(vname);
    if (creating) {
        fd = shm_open(name, O_RDWR | O_CREAT | O_EXCL, 0600);
        if (fd < 0) {
            CAMLreturn(map_error(errno == EEXIST ? QR_ERR_EXISTS : QR_ERR_SHM_OPEN));
        }
        created = 1;
        /* Brand-new object (O_EXCL). Size is 0; truncate once to the
           requested length. An existing object never reaches here, so
           this cannot resize a live peer's mapping. */
        if (ftruncate(fd, (off_t)bytes) != 0) {
            close(fd);
            shm_unlink(name);
            CAMLreturn(map_error(QR_ERR_TRUNCATE));
        }
    } else {
        struct stat st;
        fd = shm_open(name, O_RDWR, 0600);
        if (fd < 0) {
            CAMLreturn(map_error(errno == ENOENT ? QR_ERR_NOT_FOUND : QR_ERR_SHM_OPEN));
        }
        if (fstat(fd, &st) != 0) {
            close(fd);
            CAMLreturn(map_error(QR_ERR_STAT));
        }
        /* W1: never mmap past the object. A short region is an error. */
        if (st.st_size < (off_t)bytes) {
            close(fd);
            CAMLreturn(map_error(QR_ERR_TOO_SMALL));
        }
    }

    p = mmap(hint, bytes, PROT_READ | PROT_WRITE, flags, fd, 0);
    if (p == MAP_FAILED) {
        int e = (errno == EEXIST) ? QR_ERR_INUSE : QR_ERR_MMAP;
        close(fd);
        if (created) shm_unlink(name);
        CAMLreturn(map_error(e));
    }
    close(fd);
    /* munmap is paired with the failure paths above; the success path
       hands the mapping to the Bigarray for the life of the region.
       qr_unmap releases it explicitly. */
    CAMLreturn(finish_map(p, bytes));
}

/* Drop a named object the caller has already decided is a dead session,
   then exclusively create a fresh one of [words]. Does not ftruncate an
   object that already exists: unlink first, then O_EXCL. */
CAMLprim value qr_reclaim(value vname, value vwords, value vaddr)
{
    CAMLparam3(vname, vwords, vaddr);
    if (caml_string_length(vname) == 0) CAMLreturn(map_error(QR_ERR_RANGE));
    shm_unlink(String_val(vname));
    CAMLreturn(qr_map(vname, vwords, Val_true, vaddr));
}

CAMLprim value qr_unlink(value vname)
{
    if (caml_string_length(vname) > 0) shm_unlink(String_val(vname));
    return Val_unit;
}

CAMLprim value qr_unmap(value vba)
{
    void *p = Caml_ba_data_val(vba);
    intnat n = Caml_ba_array_val(vba)->dim[0];
    if (p != NULL && p != &qr_dummy_word && n > 0)
        munmap(p, (size_t)n * 8);
    Caml_ba_array_val(vba)->data = &qr_dummy_word;
    Caml_ba_array_val(vba)->dim[0] = 1;
    return Val_unit;
}

CAMLprim value qr_lock(value vba)
{
    void *p = Caml_ba_data_val(vba);
    size_t bytes = (size_t)Caml_ba_array_val(vba)->dim[0] * 8;
    return Val_bool(p != NULL && mlock(p, bytes) == 0);
}

CAMLprim value qr_base_addr(value vba)
{
    return caml_copy_nativeint((intnat)Caml_ba_data_val(vba));
}

/* Exclusive lock for Region.recover. The lock object is a sibling shm
   name (name + "_lk") that is never unlinked by reclaim, so two producers
   cannot both observe a dead session and then unlink each other's
   replacement. O_EXCL creates it once; everyone else opens the same inode
   and blocks in flock. */
CAMLprim value qr_session_lock(value vname)
{
    CAMLparam1(vname);
    char lockname[256];
    int fd, rc;
    if (caml_string_length(vname) == 0
        || (size_t)caml_string_length(vname) + 4 >= sizeof lockname) {
        CAMLreturn(Val_long(-1));
    }
    memcpy(lockname, String_val(vname), caml_string_length(vname));
    memcpy(lockname + caml_string_length(vname), "_lk", 4);
    fd = shm_open(lockname, O_RDWR | O_CREAT | O_EXCL, 0600);
    if (fd < 0 && errno == EEXIST)
        fd = shm_open(lockname, O_RDWR, 0600);
    if (fd < 0) CAMLreturn(Val_long(-1));
    caml_release_runtime_system();
    rc = flock(fd, LOCK_EX);
    caml_acquire_runtime_system();
    if (rc != 0) {
        close(fd);
        CAMLreturn(Val_long(-1));
    }
    CAMLreturn(Val_long(fd));
}

CAMLprim value qr_session_unlock(value vfd)
{
    int fd = (int)Long_val(vfd);
    if (fd >= 0) {
        flock(fd, LOCK_UN);
        close(fd);
    }
    return Val_unit;
}

CAMLprim value qr_pid_alive(value vpid)
{
    int pid = (int)Long_val(vpid);
    if (pid <= 0) return Val_false;
    if (kill(pid, 0) == 0) return Val_true;
    return Val_bool(errno == EPERM);
}

/* ------------------------------------------------------------------ */
/* Atomics. Hot-path counters are OCaml ints (63-bit, sign-extended   */
/* into the int64 slot). No caml_copy_int64, so these are noalloc.    */
/* ------------------------------------------------------------------ */

CAMLprim value qr_load_int(value vba, value vidx)
{
    int64_t *a = (int64_t *)Caml_ba_data_val(vba);
    int64_t x = __atomic_load_n(&a[Long_val(vidx)], __ATOMIC_ACQUIRE);
    return Val_long((intnat)x);
}

CAMLprim value qr_load_int_relaxed(value vba, value vidx)
{
    int64_t *a = (int64_t *)Caml_ba_data_val(vba);
    int64_t x = __atomic_load_n(&a[Long_val(vidx)], __ATOMIC_RELAXED);
    return Val_long((intnat)x);
}

CAMLprim value qr_store_int(value vba, value vidx, value vx)
{
    int64_t *a = (int64_t *)Caml_ba_data_val(vba);
    __atomic_store_n(&a[Long_val(vidx)], (int64_t)Long_val(vx), __ATOMIC_RELEASE);
    return Val_unit;
}

CAMLprim value qr_store_int_relaxed(value vba, value vidx, value vx)
{
    int64_t *a = (int64_t *)Caml_ba_data_val(vba);
    __atomic_store_n(&a[Long_val(vidx)], (int64_t)Long_val(vx), __ATOMIC_RELAXED);
    return Val_unit;
}

CAMLprim value qr_fetch_add_int(value vba, value vidx, value vx)
{
    int64_t *a = (int64_t *)Caml_ba_data_val(vba);
    int64_t prev = __atomic_fetch_add(&a[Long_val(vidx)],
                                      (int64_t)Long_val(vx),
                                      __ATOMIC_ACQ_REL);
    return Val_long((intnat)prev);
}

CAMLprim value qr_cas_int(value vba, value vidx, value vold, value vnew)
{
    int64_t *a = (int64_t *)Caml_ba_data_val(vba);
    int64_t old = (int64_t)Long_val(vold);
    int64_t newv = (int64_t)Long_val(vnew);
    int ok = __atomic_compare_exchange_n(&a[Long_val(vidx)], &old, newv,
                                         0, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE);
    return Val_bool(ok);
}

/* Boxed int64 in, no fresh box out. The caller already owns [vx]. */
CAMLprim value qr_store_int64(value vba, value vidx, value vx)
{
    int64_t *a = (int64_t *)Caml_ba_data_val(vba);
    __atomic_store_n(&a[Long_val(vidx)], Int64_val(vx), __ATOMIC_RELAXED);
    return Val_unit;
}

CAMLprim value qr_load_int64(value vba, value vidx)
{
    int64_t *a = (int64_t *)Caml_ba_data_val(vba);
    int64_t x = __atomic_load_n(&a[Long_val(vidx)], __ATOMIC_ACQUIRE);
    return caml_copy_int64(x);
}

/* Signed compare of slot[idx] ? boxed int64. Returns -1/0/1. */
CAMLprim value qr_cmp_int64(value vba, value vidx, value vx)
{
    int64_t *a = (int64_t *)Caml_ba_data_val(vba);
    int64_t y = __atomic_load_n(&a[Long_val(vidx)], __ATOMIC_RELAXED);
    int64_t x = Int64_val(vx);
    return Val_int((y > x) - (y < x));
}

CAMLprim value qr_cmp_words(value vba, value ia, value ib)
{
    int64_t *a = (int64_t *)Caml_ba_data_val(vba);
    int64_t x = __atomic_load_n(&a[Long_val(ia)], __ATOMIC_RELAXED);
    int64_t y = __atomic_load_n(&a[Long_val(ib)], __ATOMIC_RELAXED);
    return Val_int((x > y) - (x < y));
}

CAMLprim value qr_copy_words(value vdst, value vdoff, value vsrc, value vsoff, value vn)
{
    int64_t *d = (int64_t *)Caml_ba_data_val(vdst);
    int64_t *s = (int64_t *)Caml_ba_data_val(vsrc);
    intnat ddim = Caml_ba_array_val(vdst)->dim[0];
    intnat sdim = Caml_ba_array_val(vsrc)->dim[0];
    intnat doff = Long_val(vdoff);
    intnat soff = Long_val(vsoff);
    intnat n = Long_val(vn);
    if (n < 0 || doff < 0 || soff < 0 || n > ddim || n > sdim
        || doff > ddim - n || soff > sdim - n)
        return Val_false;
    if (n > 0) memmove(d + doff, s + soff, (size_t)n * 8);
    return Val_true;
}

/* ------------------------------------------------------------------ */
/* splitmix64. Shared by Pmap priorities and Merkle. One definition   */
/* so the OCaml proof path and the C update path cannot drift.        */
/* ------------------------------------------------------------------ */

static int64_t mix64(int64_t x)
{
    uint64_t z = (uint64_t)x + 0x9E3779B97F4A7C15ULL;
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
    return (int64_t)(z ^ (z >> 31));
}

static int64_t mix2(int64_t a, int64_t b)
{
    uint64_t m = (uint64_t)mix64(a) ^ ((uint64_t)b * 0xD6E8FEB86659FD93ULL);
    return mix64((int64_t)m);
}

CAMLprim value qr_store_mix(value vba, value vidx, value vkey)
{
    int64_t *a = (int64_t *)Caml_ba_data_val(vba);
    __atomic_store_n(&a[Long_val(vidx)], mix64(Int64_val(vkey)), __ATOMIC_RELAXED);
    return Val_unit;
}

CAMLprim value qr_mix64(value vx)
{
    int64_t x = mix64(Int64_val(vx));
    return caml_copy_int64(x);
}

CAMLprim value qr_mix2(value va, value vb)
{
    int64_t x = mix2(Int64_val(va), Int64_val(vb));
    return caml_copy_int64(x);
}

CAMLprim value qr_merkle_init(value vba, value vleaves)
{
    int64_t *a = (int64_t *)Caml_ba_data_val(vba);
    intnat leaves = Long_val(vleaves);
    intnat i, n;
    if (leaves <= 0) return Val_unit;
    n = leaves * 2;
    for (i = 0; i < n; i++)
        __atomic_store_n(&a[i], 0, __ATOMIC_RELAXED);
    if (leaves == 1) {
        __atomic_store_n(&a[1], 0, __ATOMIC_RELEASE);
        return Val_unit;
    }
    for (i = leaves - 1; i >= 1; i--) {
        int64_t left = __atomic_load_n(&a[2 * i], __ATOMIC_RELAXED);
        int64_t right = __atomic_load_n(&a[2 * i + 1], __ATOMIC_RELAXED);
        int64_t h = mix2(left, right);
        if (i == 1)
            __atomic_store_n(&a[1], h, __ATOMIC_RELEASE);
        else
            __atomic_store_n(&a[i], h, __ATOMIC_RELAXED);
    }
    return Val_unit;
}

/* Leaf then parents, root last with a release store (W6). A reader that
   acquire-loads word 1 before touching children sees this update whole. */
CAMLprim value qr_merkle_update(value vba, value vleaves, value vj, value vval)
{
    int64_t *a = (int64_t *)Caml_ba_data_val(vba);
    intnat leaves = Long_val(vleaves);
    intnat j = Long_val(vj);
    intnat i;
    if (leaves <= 0 || j < 0 || j >= leaves) return Val_unit;
    i = leaves + j;
    if (i == 1) {
        __atomic_store_n(&a[1], mix64(Int64_val(vval)), __ATOMIC_RELEASE);
        return Val_unit;
    }
    __atomic_store_n(&a[i], mix64(Int64_val(vval)), __ATOMIC_RELAXED);
    while (i > 1) {
        intnat parent = i >> 1;
        intnat left = parent << 1;
        int64_t h = mix2(__atomic_load_n(&a[left], __ATOMIC_RELAXED),
                         __atomic_load_n(&a[left + 1], __ATOMIC_RELAXED));
        i = parent;
        if (i == 1)
            __atomic_store_n(&a[1], h, __ATOMIC_RELEASE);
        else
            __atomic_store_n(&a[i], h, __ATOMIC_RELAXED);
    }
    return Val_unit;
}

CAMLprim value qr_merkle_root(value vba)
{
    int64_t *a = (int64_t *)Caml_ba_data_val(vba);
    int64_t x = __atomic_load_n(&a[1], __ATOMIC_ACQUIRE);
    return caml_copy_int64(x);
}

/* Pthread stress of the same CAS-max vs fetch-add pattern Vclock.merge
   and Vclock.tick use. Host systhreads hold the OCaml runtime lock across
   noalloc stubs, so they cannot interleave the OCaml loop; this runs the
   race below the lock. Returns 0 on success, 1 on pthread failure, 2 if
   the cell decreased or finished below max(merges, iters). */
struct qr_race {
    int64_t *cell;
    int64_t merges;
    int iters;
    int bad;
};

static void *qr_ticker(void *arg)
{
    struct qr_race *r = arg;
    int i;
    for (i = 0; i < r->iters; i++)
        __atomic_fetch_add(r->cell, 1, __ATOMIC_ACQ_REL);
    return NULL;
}

static void *qr_merger(void *arg)
{
    struct qr_race *r = arg;
    int i;
    for (i = 0; i < r->iters; i++) {
        for (;;) {
            int64_t a = __atomic_load_n(r->cell, __ATOMIC_ACQUIRE);
            if (r->merges <= a) break;
            if (__atomic_compare_exchange_n(r->cell, &a, r->merges,
                                            0, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE))
                break;
        }
    }
    return NULL;
}

static void *qr_sampler(void *arg)
{
    struct qr_race *r = arg;
    int64_t prev = 0;
    int i;
    for (i = 0; i < r->iters * 4; i++) {
        int64_t v = __atomic_load_n(r->cell, __ATOMIC_ACQUIRE);
        if (v < prev) __atomic_store_n(&r->bad, 1, __ATOMIC_RELAXED);
        prev = v;
    }
    return NULL;
}

CAMLprim value qr_atomic_max_self_test(value vba, value vidx, value vmerge, value viters)
{
    int64_t *a = (int64_t *)Caml_ba_data_val(vba);
    struct qr_race r;
    pthread_t tt, mt, st;
    int64_t final, need;
    int spawned = 0;
    int rc = 0;
    r.cell = &a[Long_val(vidx)];
    r.merges = (int64_t)Long_val(vmerge);
    r.iters = (int)Long_val(viters);
    r.bad = 0;
    __atomic_store_n(r.cell, 0, __ATOMIC_RELAXED);
    caml_release_runtime_system();
    if (pthread_create(&tt, NULL, qr_ticker, &r) == 0) spawned |= 1;
    else rc = 1;
    if (rc == 0 && pthread_create(&mt, NULL, qr_merger, &r) == 0) spawned |= 2;
    else rc = 1;
    if (rc == 0 && pthread_create(&st, NULL, qr_sampler, &r) == 0) spawned |= 4;
    else rc = 1;
    if (spawned & 1) pthread_join(tt, NULL);
    if (spawned & 2) pthread_join(mt, NULL);
    if (spawned & 4) pthread_join(st, NULL);
    final = __atomic_load_n(r.cell, __ATOMIC_ACQUIRE);
    caml_acquire_runtime_system();
    if (rc != 0) return Val_int(1);
    need = r.merges > (int64_t)r.iters ? r.merges : (int64_t)r.iters;
    if (r.bad || final < need) return Val_int(2);
    return Val_int(0);
}

CAMLprim value qr_monotonic_ns(value vunit)
{
    struct timespec ts;
    (void)vunit;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0)
        return caml_copy_int64(0);
    return caml_copy_int64(((int64_t)ts.tv_sec * 1000000000LL) + ts.tv_nsec);
}

CAMLprim value qr_eagain(value vunit)
{
    (void)vunit;
    return Val_int(EAGAIN);
}

CAMLprim value qr_enotsup(value vunit)
{
    (void)vunit;
#ifdef ENOTSUP
    return Val_int(ENOTSUP);
#else
    return Val_int(EOPNOTSUPP);
#endif
}

CAMLprim value qr_esrch(value vunit)
{
    (void)vunit;
    return Val_int(ESRCH);
}

CAMLprim value qr_have_qnx_ipc(value vunit)
{
    (void)vunit;
#ifdef __QNXNTO__
    return Val_true;
#else
    return Val_false;
#endif
}

CAMLprim value qr_is_pulse(value vrcvid)
{
    return Val_bool(Long_val(vrcvid) == 0);
}

/* Pulse code sits in bits 32..39 of word 0 (little-endian struct _pulse). */
CAMLprim value qr_pulse_code(value vba)
{
    int64_t *a = (int64_t *)Caml_ba_data_val(vba);
    uint64_t w = (uint64_t)__atomic_load_n(&a[0], __ATOMIC_RELAXED);
    return Val_int((int)((w >> 32) & 0xFF));
}

/* ------------------------------------------------------------------ */
/* QNX IPC. Every call returns a negative errno instead of raising.   */
/* ENOTSUP on the host build — capability detection is qr_have_qnx_ipc, */
/* not "whatever Failure channel_create threw".                        */
/* ------------------------------------------------------------------ */

#ifdef __QNXNTO__

CAMLprim value qr_channel_create(value vunit)
{
    int chid;
    (void)vunit;
    chid = ChannelCreate(_NTO_CHF_DISCONNECT);
    if (chid < 0) return Val_long(-errno);
    return Val_long(chid);
}

CAMLprim value qr_connect_attach(value vpid, value vchid)
{
    int coid = ConnectAttach(0, Long_val(vpid), Long_val(vchid),
                             _NTO_SIDE_CHANNEL, 0);
    if (coid < 0) return Val_long(-errno);
    return Val_long(coid);
}

CAMLprim value qr_msg_send(value vcoid, value vba, value voff, value vlen, value vreply)
{
    CAMLparam5(vcoid, vba, voff, vlen, vreply);
    int64_t *a = (int64_t *)Caml_ba_data_val(vba);
    int64_t *reply = (int64_t *)Caml_ba_data_val(vreply);
    intnat dim = Caml_ba_array_val(vba)->dim[0];
    intnat rdim = Caml_ba_array_val(vreply)->dim[0];
    intnat off = Long_val(voff), len = Long_val(vlen);
    iov_t siov, riov;
    int rc;
    if (off < 0 || len < 0 || rdim < 0 || off > dim || len > dim - off) {
        CAMLreturn(Val_long(-EINVAL));
    }
    SETIOV(&siov, a + off, (size_t)len * 8);
    /* W4: the reply is the caller's buffer, not a discarded stack slot. */
    SETIOV(&riov, reply, (size_t)rdim * 8);
    caml_release_runtime_system();
    rc = MsgSendv(Long_val(vcoid), &siov, 1, &riov, 1);
    caml_acquire_runtime_system();
    if (rc < 0) CAMLreturn(Val_long(-errno));
    CAMLreturn(Val_long(rc));
}

CAMLprim value qr_msg_receive(value vchid, value vba, value voff, value vlen)
{
    CAMLparam4(vchid, vba, voff, vlen);
    CAMLlocal1(res);
    int64_t *a = (int64_t *)Caml_ba_data_val(vba);
    intnat dim = Caml_ba_array_val(vba)->dim[0];
    intnat off = Long_val(voff), len = Long_val(vlen);
    struct _msg_info info;
    int rcvid;
    if (off < 0 || len < 0 || off > dim || len > dim - off) {
        res = caml_alloc_tuple(2);
        Store_field(res, 0, Val_long(-EINVAL));
        Store_field(res, 1, Val_int(0));
        CAMLreturn(res);
    }
    caml_release_runtime_system();
    rcvid = MsgReceive(Long_val(vchid), a + off, (size_t)len * 8, &info);
    caml_acquire_runtime_system();
    res = caml_alloc_tuple(2);
    if (rcvid < 0) {
        Store_field(res, 0, Val_long(-errno));
        Store_field(res, 1, Val_int(0));
    } else {
        Store_field(res, 0, Val_long(rcvid));
        Store_field(res, 1, Val_int((intnat)info.msglen));
    }
    CAMLreturn(res);
}

CAMLprim value qr_msg_reply(value vrcvid, value vstatus)
{
    int rc = MsgReply(Long_val(vrcvid), Long_val(vstatus), NULL, 0);
    if (rc < 0) return Val_long(-errno);
    return Val_long(0);
}

CAMLprim value qr_msg_replyv(value vrcvid, value vstatus, value vba,
                             value voff, value vlen)
{
    CAMLparam5(vrcvid, vstatus, vba, voff, vlen);
    int64_t *a = (int64_t *)Caml_ba_data_val(vba);
    intnat dim = Caml_ba_array_val(vba)->dim[0];
    intnat off = Long_val(voff), len = Long_val(vlen);
    iov_t riov;
    int rc;
    if (off < 0 || len < 0 || off > dim || len > dim - off)
        CAMLreturn(Val_long(-EINVAL));
    SETIOV(&riov, a + off, (size_t)len * 8);
    caml_release_runtime_system();
    rc = MsgReplyv(Long_val(vrcvid), Long_val(vstatus), &riov, 1);
    caml_acquire_runtime_system();
    if (rc < 0) CAMLreturn(Val_long(-errno));
    CAMLreturn(Val_long(0));
}

CAMLprim value qr_msg_send_pulse(value vcoid, value vcode, value vvalue)
{
    int rc;
    caml_release_runtime_system();
    rc = MsgSendPulse(Long_val(vcoid), -1, Int_val(vcode), (long)Long_val(vvalue));
    caml_acquire_runtime_system();
    /* EAGAIN is -errno, not an exception (E2). */
    if (rc < 0) return Val_long(-errno);
    return Val_long(0);
}

CAMLprim value qr_sched_fifo(value vprio)
{
    struct sched_param p = {0};
    p.sched_priority = Int_val(vprio);
    if (pthread_setschedparam(pthread_self(), SCHED_FIFO, &p) != 0) {
        fprintf(stderr, "sched_fifo: pthread_setschedparam failed (errno %d)\n", errno);
    }
    return Val_unit;
}

CAMLprim value qr_set_runmask(value vcpu)
{
    long cpu = Long_val(vcpu);
    uintptr_t mask;
    if (cpu < 0 || (unsigned long)cpu >= sizeof(uintptr_t) * 8) {
        fprintf(stderr, "set_runmask: cpu out of range\n");
        return Val_unit;
    }
    mask = (uintptr_t)1 << (unsigned)cpu;
    if (ThreadCtl(_NTO_TCTL_RUNMASK, (void *)mask) != 0)
        fprintf(stderr, "set_runmask: ThreadCtl failed (errno %d)\n", errno);
    return Val_unit;
}

#else /* host build */

static value host_unsupported(void) { return Val_long(-ENOTSUP); }

CAMLprim value qr_channel_create(value a)
{
    (void)a;
    return host_unsupported();
}
CAMLprim value qr_connect_attach(value a, value b)
{
    (void)a; (void)b;
    return host_unsupported();
}
CAMLprim value qr_msg_send(value a, value b, value c, value d, value e)
{
    (void)a; (void)b; (void)c; (void)d; (void)e;
    return host_unsupported();
}
CAMLprim value qr_msg_receive(value a, value b, value c, value d)
{
    CAMLparam4(a, b, c, d);
    CAMLlocal1(res);
    (void)a; (void)b; (void)c; (void)d;
    res = caml_alloc_tuple(2);
    Store_field(res, 0, Val_long(-ENOTSUP));
    Store_field(res, 1, Val_int(0));
    CAMLreturn(res);
}
CAMLprim value qr_msg_reply(value a, value b)
{
    (void)a; (void)b;
    return host_unsupported();
}
CAMLprim value qr_msg_replyv(value a, value b, value c, value d, value e)
{
    (void)a; (void)b; (void)c; (void)d; (void)e;
    return host_unsupported();
}
CAMLprim value qr_msg_send_pulse(value a, value b, value c)
{
    (void)a; (void)b; (void)c;
    return host_unsupported();
}

static void qnx_noop(const char *what)
{
    fprintf(stderr, "host: %s is QNX-only; no-op on this build\n", what);
}

CAMLprim value qr_sched_fifo(value vprio)
{
    (void)vprio;
    qnx_noop("SCHED_FIFO priority");
    return Val_unit;
}

CAMLprim value qr_set_runmask(value vcpu)
{
    long cpu = Long_val(vcpu);
    if (cpu < 0 || (unsigned long)cpu >= sizeof(uintptr_t) * 8) {
        fprintf(stderr, "set_runmask: cpu out of range\n");
        return Val_unit;
    }
    qnx_noop("CPU runmask pinning");
    return Val_unit;
}

#endif
