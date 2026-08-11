(* One preallocated, page-locked slab of int64 words. Every structure in
   this library lives inside a [slice] of it; no structure allocates OCaml
   heap memory in steady state. *)

type words =
  (int64, Bigarray.int64_elt, Bigarray.c_layout) Bigarray.Array1.t

external map_c : string -> int -> bool -> nativeint -> words = "qr_map"
external lock : words -> bool = "qr_lock"
external base_addr : words -> nativeint = "qr_base_addr"
external unlink : string -> unit = "qr_unlink"
external load_acq : words -> int -> int64 = "qr_load_acq"
external store_rel : words -> int -> int64 -> unit = "qr_store_rel"
external fetch_add : words -> int -> int64 -> int64 = "qr_fetch_add"

(* Monotonic clock (SPEC A.9): nanoseconds since an arbitrary origin, from
   CLOCK_MONOTONIC — never CLOCK_REALTIME, which can jump. Works on QNX and
   on the host (glibc provides the same call). *)
external monotonic_ns : unit -> int64 = "qr_monotonic_ns"

(* QNX IPC control plane. rcvid contract (memorize):
     rcvid > 0  a real message — you MUST reply, on every code path
     rcvid == 0 a pulse       — handle it, NEVER reply
     rcvid < 0  error         — diagnose, do not reply
   The host build keeps these symbols but raises Failure if called, so a
   demo can probe [channel_create] to pick the pulse path vs the polling
   fallback. *)
external channel_create : unit -> int = "qr_channel_create"
external connect_attach : int -> int -> int = "qr_connect_attach"
external is_pulse : int -> bool = "qr_is_pulse"
external msg_send : int -> words -> int -> int -> int = "qr_msg_send"
external msg_receive : int -> words -> int -> int -> int * int = "qr_msg_receive"
external msg_reply : int -> int -> unit = "qr_msg_reply"
external msg_replyv : int -> int -> words -> int -> int -> unit = "qr_msg_replyv"
external msg_send_pulse : int -> int -> int64 -> unit = "qr_msg_send_pulse"

(* Real-time posture (SPEC B.1): SCHED_FIFO priority + BMP-style CPU
   pinning. QNX-only; on the host these are no-ops that log to stderr so
   the demo keeps running under `make demo`. Priorities must stay <= 63
   for an unprivileged qnxuser (no PROCMGR_AID_PRIORITY needed). *)
external sched_fifo : int -> unit = "qr_sched_fifo"
external set_runmask : int -> unit = "qr_set_runmask"

type t = { mem : words; locked : bool; mutable cursor : int }

(* Monotonic seconds — float convenience over [monotonic_ns]. *)
let monotonic () = Int64.to_float (monotonic_ns ()) /. 1e9

(* [create ~name ~words ?addr] maps (creating if needed) and pre-faults the
   whole region, then best-effort pins it. [addr] requests MAP_FIXED so every
   process sees identical placement and word-indices act as pointers. *)
let create ?(name = "") ?(addr = 0n) ~words () =
  let mem = map_c name words true addr in
  let locked = lock mem in
  { mem; locked; cursor = 0 }

let attach ~name ?(addr = 0n) ~words () =
  let mem = map_c name words false addr in
  { mem; locked = lock mem; cursor = 0 }

(* Bump-allocate a slice at init time. This is the ONLY allocator here, and
   it is monotone: carve everything before entering steady state. *)
let slice t n =
  if t.cursor + n > Bigarray.Array1.dim t.mem then
    failwith "region exhausted: size the slab before steady state";
  let s = Bigarray.Array1.sub t.mem t.cursor n in
  t.cursor <- t.cursor + n;
  s

let dim (w : words) = Bigarray.Array1.dim w
