(** Pre-faulted slab of int64 words.

    A region is one mapping (anonymous, or a POSIX shared-memory object)
    plus an 8-word layout descriptor at the front:

    {[
      0 magic | 1 version | 2 size in words | 3 state
      4 epoch (creator pid) | 5 generation | 6–7 reserved
    ]}

    [attach] checks the descriptor and the underlying object size, so a
    short or skewed mapping is an error instead of a fault. [publish]
    release-stores state = ready last; peers acquire-load it via [is_ready].

    Hot-path word access ([load_int], [store_int], [fetch_add_int],
    [cas_int], [copy_words]) does not allocate. Counters are 63-bit OCaml
    ints sign-extended into the int64 slot — ample for monotone indexes,
    and the reason a steady-state loop can stay off the OCaml heap.
    [load_int64] boxes; it is for proofs and diagnostics, not hot paths.

    QNX IPC is detected with [have_qnx_ipc]. The host build returns
    [-enotsup] from the stubs and [Error `unavailable] from
    [channel_create]. Callers must not treat an arbitrary exception as
    "we are not on QNX". *)

type words =
  (int64, Bigarray.int64_elt, Bigarray.c_layout) Bigarray.Array1.t

type t

type error =
  | Exhausted
  | Too_small
  | Size_mismatch
  | Bad_magic
  | Bad_version
  | Uninitialized
  | Exists
  | Busy
  | Not_found
  | Map_failed
  | Fixed_unsupported
  | In_use
  | Stat
  | Truncate
  | Range

val descr_words : int
val layout_version : int
val error_to_string : error -> string

val dim_words : words -> int
val dim : t -> int
val locked : t -> bool
val cursor : t -> int
val backing : t -> words
val base_addr : words -> nativeint

val create :
  ?name:string -> ?addr:nativeint -> ?epoch:int -> ?generation:int ->
  words:int -> unit -> (t, error) result
(** [create ~words] maps a fresh region and writes the descriptor in
    state [init]. [epoch] defaults to this process's pid, so a later
    [recover] can tell a live creator from a dead one. An empty [name] is
    a private anonymous mapping. A non-empty name is created with
    [O_CREAT|O_EXCL] while the session lock is held, and is not resized if
    it already exists. *)

val attach :
  name:string -> ?addr:nativeint -> words:int -> unit -> (t, error) result
(** Map an existing object. Fails with [Too_small] when the object is
    shorter than [words] (no SIGBUS), [Uninitialized] when the descriptor
    magic is still zero, [Bad_magic] / [Bad_version] / [Size_mismatch]
    when the descriptor does not match. *)

val recover :
  ?addr:nativeint -> name:string -> epoch:int -> words:int -> unit ->
  (t, error) result
(** Take over a named region whose creator pid is dead, or whose descriptor
    was never written. The check and the replacement run under an exclusive
    lock, so two producers cannot each unlink the other's fresh region.
    A creator that is still alive — published or not — yields [Error Busy].
    Foreign magic is not reclaimed. *)

val unlink : string -> unit
val unmap : t -> unit
val publish : t -> unit
val is_ready : t -> bool
val epoch : t -> int
val generation : t -> int
val creator_alive : t -> bool
(** [kill(epoch, 0)] — false when the creating pid is gone. Peers use this
    to reject a ready-looking region left behind by a dead producer. *)

val slice : t -> int -> (words, error) result
(** Init-time bump allocator. [Error Exhausted] instead of an exception.
    Not a steady-state operation: the result block itself is heap. *)

val load_int : words -> int -> int
val store_int : words -> int -> int -> unit
val load_relaxed : words -> int -> int
val store_relaxed : words -> int -> int -> unit
val fetch_add_int : words -> int -> int -> int
val cas_int : words -> int -> int -> int -> bool
val store_int64 : words -> int -> int64 -> unit
val load_int64 : words -> int -> int64
val cmp_int64 : words -> int -> int64 -> int
val cmp_words : words -> int -> int -> int
val copy_words : words -> int -> words -> int -> int -> bool
val store_mix : words -> int -> int64 -> unit

val monotonic_ns : unit -> int64
val monotonic : unit -> float

val have_qnx_ipc : unit -> bool
val eagain : int
val enotsup : int
val esrch : int

val channel_create : unit -> (int, [ `unavailable | `os of int ]) result
val connect_attach : int -> int -> int
val is_pulse : int -> bool
val pulse_code : words -> int

val msg_send : int -> words -> int -> int -> words -> int
(** [msg_send coid src off len reply] sends [src\[off, off+len\)] and
    writes the reply into [reply]. Returns the [MsgReply] status (>= 0)
    or a negative errno. The reply bytes are the contents of [reply],
    not a discarded stack buffer. *)

val msg_receive : int -> words -> int -> int -> int * int
val msg_reply : int -> int -> int
val msg_replyv : int -> int -> words -> int -> int -> int
val msg_send_pulse : int -> int -> int -> int
(** [msg_send_pulse coid code value] returns 0, or a negative errno.
    [EAGAIN] ([-eagain]) means the receiver's pulse pool is exhausted;
    it does not raise. *)

val sched_fifo : int -> unit
val set_runmask : int -> unit

val atomic_max_self_test : words -> int -> int -> int -> int
(** Pthread CAS-max versus fetch-add on one cell. Returns 0 when the
    cell stayed monotone and finished at least at [max merges iters]. *)
