/* Positive/negative fixtures for tools/opengrep/qnxml.yml (C rules).
 * ruleid = must match the immediately-following code line;
 * ok     = must NOT match that line.
 * Stack only ruleid (or only ok) comments — never interleave before one line.
 * Run: make opengrep-test
 *
 * Parsed as plain C (no CAMLprim token pair). Mirrors the sed-transformed
 * stubs shape used by `make opengrep`. */

#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <errno.h>

typedef long value;
#define Long_val(v) ((long)(v))
#define Bool_val(v) ((int)(v))
#define String_val(v) ((char *)(v))
#define Val_unit 0
value caml_copy_int64(int64_t x);
value caml_failwith(char *msg);
void caml_release_runtime_system(void);
void caml_acquire_runtime_system(void);
int MsgSendv(long coid, void *s, int ns, void *r, int nr);
int MsgReceive(long chid, void *buf, size_t n, void *info);
int MsgReplyv(long rcvid, long status, void *r, int nr);
int MsgSendPulse(long coid, int prio, int code, long val);
int ftruncate(int fd, long length);
int shm_open(const char *name, int oflag, int mode);
int ConnectAttach(int nd, long pid, long chid, int index, int flags);

/* --- qnxml-map-fixed-silent-overwrite --- */
void map_fixed_bad(void)
{
    int flags = 0;
    /* ruleid: qnxml-map-fixed-silent-overwrite */
    flags |= MAP_FIXED;
    (void)flags;
}

void map_fixed_ok(void)
{
    int flags = 0;
    /* ok: qnxml-map-fixed-silent-overwrite */
    flags |= MAP_SHARED;
    (void)flags;
}

/* --- qnxml-msgsendv-reply-discarded --- */
int send_discards_reply(long coid, void *siov, void *riov)
{
    int rc;
    caml_release_runtime_system();
    /* ruleid: qnxml-msgsendv-reply-discarded */
    rc = MsgSendv(coid, &siov, 1, &riov, 1);
    caml_acquire_runtime_system();
    return rc;
}

/* --- qnxml-blocking-call-holds-runtime-lock --- */
int blocking_holds_lock(long chid, void *buf, size_t n)
{
    /* ruleid: qnxml-blocking-call-holds-runtime-lock */
    return MsgReceive(chid, buf, n, NULL);
}

int blocking_releases_lock(long chid, void *buf, size_t n)
{
    int rc;
    caml_release_runtime_system();
    /* ok: qnxml-blocking-call-holds-runtime-lock */
    rc = MsgReceive(chid, buf, n, NULL);
    caml_acquire_runtime_system();
    return rc;
}

/* --- qnxml-pulse-eagain-crashes-producer --- */
void pulse_hard_fail(void)
{
    /* ruleid: qnxml-pulse-eagain-crashes-producer */
    caml_failwith("MsgSendPulse");
}

int pulse_soft_fail(int rc)
{
    /* ok: qnxml-pulse-eagain-crashes-producer */
    if (rc < 0) return -1;
    return 0;
}

/* --- qnxml-ftruncate-resizes-shared-object --- */
int resize_shared(int fd, size_t bytes)
{
    /* ruleid: qnxml-ftruncate-resizes-shared-object */
    return ftruncate(fd, (long)bytes);
}

int no_resize(int fd)
{
    /* ok: qnxml-ftruncate-resizes-shared-object */
    (void)fd;
    return 0;
}

/* --- qnxml-unchecked-shift-amount --- */
uintptr_t bad_shift(value vcpu)
{
    /* ruleid: qnxml-unchecked-shift-amount */
    return (uintptr_t)1 << Long_val(vcpu);
}

uintptr_t ok_shift(value vcpu)
{
    long cpu = Long_val(vcpu);
    if (cpu < 0 || cpu >= 64) return 0;
    /* ok: qnxml-unchecked-shift-amount */
    return (uintptr_t)1 << (unsigned)cpu;
}

/* --- qnxml-caml-copy-int64-hot-path --- */
static value qr_load_acq(value vba, value vidx)
{
    int64_t x = 0;
    (void)vba; (void)vidx;
    /* ruleid: qnxml-caml-copy-int64-hot-path */
    return caml_copy_int64(x);
}

static value qr_fetch_add(value vba, value vidx, value vx)
{
    int64_t x = 0;
    (void)vba; (void)vidx; (void)vx;
    /* ruleid: qnxml-caml-copy-int64-hot-path */
    return caml_copy_int64(x);
}

static value qr_monotonic_ns(value vunit)
{
    (void)vunit;
    /* ok: qnxml-caml-copy-int64-hot-path */
    return caml_copy_int64(0);
}

/* --- qnxml-mmap-without-munmap --- */
void *map_leaks(size_t bytes)
{
    void *p;
    /* ruleid: qnxml-mmap-without-munmap */
    p = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) return NULL;
    return p;
}

void *map_cleaned(size_t bytes)
{
    void *p;
    /* ok: qnxml-mmap-without-munmap */
    p = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) return NULL;
    if (bytes == 0) {
        munmap(p, bytes);
        return NULL;
    }
    return p;
}

/* --- qnxml-map-size-overflow --- */
size_t bytes_overflow(value vwords)
{
    /* ruleid: qnxml-map-size-overflow */
    return (size_t)Long_val(vwords) * 8;
}

size_t bytes_checked(value vwords)
{
    long w = Long_val(vwords);
    if (w < 0 || (size_t)w > (SIZE_MAX / 8)) return 0;
    /* ok: qnxml-map-size-overflow */
    return (size_t)w * 8u;
}

/* --- qnxml-failwith-discards-errno --- */
void open_discards_errno(int fd)
{
    /* ruleid: qnxml-failwith-discards-errno */
    if (fd < 0) caml_failwith("shm_open");
}

void open_keeps_errno(int fd)
{
    /* ok: qnxml-failwith-discards-errno */
    if (fd < 0) {
        /* real code should caml_uerror("shm_open", ...); */
        return;
    }
}

/* --- qnxml-zero-length-memset --- */
void dead_memset(void *p)
{
    /* ruleid: qnxml-zero-length-memset */
    memset(p, 0, 0);
}

void real_memset(void *p, size_t n)
{
    /* ok: qnxml-zero-length-memset */
    memset(p, 0, n);
}

/* --- qnxml-shm-create-without-excl (stale shared-object / multi-generation) --- */
int create_shared_racy(const char *name)
{
    /* ruleid: qnxml-shm-create-without-excl */
    int oflag = O_RDWR | O_CREAT;
    return shm_open(name, oflag, 0600);
}

int create_shared_excl(const char *name)
{
    /* ok: qnxml-shm-create-without-excl */
    int oflag = O_RDWR | O_CREAT | O_EXCL;
    return shm_open(name, oflag, 0600);
}

/* --- qnxml-attach-without-fstat-size --- */
void *attach_no_size_check(const char *name, size_t bytes)
{
    int fd = shm_open(name, O_RDWR, 0600);
    void *p;
    /* ruleid: qnxml-attach-without-fstat-size, qnxml-mmap-without-munmap */
    p = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    return p;
}

void *attach_with_fstat(const char *name, size_t bytes)
{
    int fd = shm_open(name, O_RDWR, 0600);
    struct stat st;
    void *p;
    fstat(fd, &st);
    if ((size_t)st.st_size < bytes) return NULL;
    /* ok: qnxml-attach-without-fstat-size */
    p = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (p == MAP_FAILED) return NULL;
    if (bytes == 0) {
        munmap(p, bytes);
        return NULL;
    }
    return p;
}

/* --- qnxml-connect-attach-discards-errno --- */
int connect_hard_fail(long pid, long chid)
{
    int coid = ConnectAttach(0, pid, chid, 0, 0);
    /* ruleid: qnxml-connect-attach-discards-errno */
    if (coid < 0) caml_failwith("ConnectAttach");
    return coid;
}

int connect_returns_error(long pid, long chid)
{
    int coid = ConnectAttach(0, pid, chid, 0, 0);
    /* ok: qnxml-connect-attach-discards-errno */
    if (coid < 0) return coid;
    return coid;
}
