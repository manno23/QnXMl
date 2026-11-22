type words =
  (int64, Bigarray.int64_elt, Bigarray.c_layout) Bigarray.Array1.t

type t = { mem : words; locked : bool; mutable cursor : int }

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

let descr_words = 8
let layout_version = 1
let magic = 0x514E5831 (* "QNX1" — fits in an unboxed OCaml int *)
let state_init = 1
let state_ready = 2

let d_magic = 0
let d_version = 1
let d_words = 2
let d_state = 3
let d_epoch = 4
let d_generation = 5

let error_to_string = function
  | Exhausted -> "exhausted"
  | Too_small -> "too_small"
  | Size_mismatch -> "size_mismatch"
  | Bad_magic -> "bad_magic"
  | Bad_version -> "bad_version"
  | Uninitialized -> "uninitialized"
  | Exists -> "exists"
  | Busy -> "busy"
  | Not_found -> "not_found"
  | Map_failed -> "map_failed"
  | Fixed_unsupported -> "fixed_unsupported"
  | In_use -> "in_use"
  | Stat -> "stat"
  | Truncate -> "truncate"
  | Range -> "range"

external map_raw : string -> int -> bool -> nativeint -> int * words = "qr_map"
external reclaim_raw : string -> int -> nativeint -> int * words = "qr_reclaim"
external unlink : string -> unit = "qr_unlink"
external unmap_raw : words -> unit = "qr_unmap"
external lock : words -> bool = "qr_lock"
external base_addr : words -> nativeint = "qr_base_addr"
external self_pid : unit -> int = "qr_getpid" [@@noalloc]
external pid_alive : int -> bool = "qr_pid_alive" [@@noalloc]
external session_lock : string -> int = "qr_session_lock"
external session_unlock : int -> unit = "qr_session_unlock"

external load_int : words -> int -> int = "qr_load_int" [@@noalloc]
external load_relaxed : words -> int -> int = "qr_load_int_relaxed" [@@noalloc]
external store_int : words -> int -> int -> unit = "qr_store_int" [@@noalloc]
external store_relaxed : words -> int -> int -> unit = "qr_store_int_relaxed" [@@noalloc]
external fetch_add_int : words -> int -> int -> int = "qr_fetch_add_int" [@@noalloc]
external cas_int : words -> int -> int -> int -> bool = "qr_cas_int" [@@noalloc]
external store_int64 : words -> int -> int64 -> unit = "qr_store_int64" [@@noalloc]
external load_int64 : words -> int -> int64 = "qr_load_int64"
external cmp_int64 : words -> int -> int64 -> int = "qr_cmp_int64" [@@noalloc]
external cmp_words : words -> int -> int -> int = "qr_cmp_words" [@@noalloc]
external copy_words : words -> int -> words -> int -> int -> bool
  = "qr_copy_words" [@@noalloc]
external store_mix : words -> int -> int64 -> unit = "qr_store_mix" [@@noalloc]

external monotonic_ns : unit -> int64 = "qr_monotonic_ns"
external eagain : unit -> int = "qr_eagain" [@@noalloc]
external enotsup : unit -> int = "qr_enotsup" [@@noalloc]
external esrch : unit -> int = "qr_esrch" [@@noalloc]
let eagain = eagain ()
let enotsup = enotsup ()
let esrch = esrch ()

external have_qnx_ipc : unit -> bool = "qr_have_qnx_ipc" [@@noalloc]
external channel_create_raw : unit -> int = "qr_channel_create" [@@noalloc]
external connect_attach : int -> int -> int = "qr_connect_attach" [@@noalloc]
external is_pulse : int -> bool = "qr_is_pulse" [@@noalloc]
external pulse_code : words -> int = "qr_pulse_code" [@@noalloc]
external msg_send : int -> words -> int -> int -> words -> int = "qr_msg_send"
external msg_receive : int -> words -> int -> int -> int * int = "qr_msg_receive"
external msg_reply : int -> int -> int = "qr_msg_reply"
external msg_replyv : int -> int -> words -> int -> int -> int = "qr_msg_replyv"
external msg_send_pulse : int -> int -> int -> int = "qr_msg_send_pulse"
external sched_fifo : int -> unit = "qr_sched_fifo"
external set_runmask : int -> unit = "qr_set_runmask"
external atomic_max_self_test : words -> int -> int -> int -> int
  = "qr_atomic_max_self_test"

let dim_words w = Bigarray.Array1.dim w
let dim t = dim_words t.mem
let locked t = t.locked
let cursor t = t.cursor
let backing t = t.mem
let monotonic () = Int64.to_float (monotonic_ns ()) /. 1e9

let error_of_code = function
  | 0 -> None
  | 2 -> Some Truncate
  | 4 -> Some Too_small
  | 5 -> Some Size_mismatch
  | 6 -> Some Exists
  | 7 -> Some Stat
  | 8 -> Some In_use
  | 9 -> Some Range
  | 10 -> Some Not_found
  | 11 -> Some Fixed_unsupported
  | _ -> Some Map_failed

let map name words create addr =
  let code, mem = map_raw name words create addr in
  match error_of_code code with
  | None -> Ok mem
  | Some e -> Error e

let write_descr t ~epoch ~generation =
  let m = t.mem in
  store_relaxed m d_version layout_version;
  store_relaxed m d_words (dim_words m);
  store_relaxed m d_state state_init;
  store_relaxed m d_epoch epoch;
  store_relaxed m d_generation generation;
  store_relaxed m 6 0;
  store_relaxed m 7 0;
  (* Release on magic publishes the descriptor. *)
  store_int m d_magic magic

let create_unlocked ?(name = "") ?(addr = 0n) ?(epoch = self_pid ())
    ?(generation = 1) ~words () =
  if words < descr_words then Error Too_small
  else
    match map name words true addr with
    | Error e -> Error e
    | Ok mem ->
        let t = { mem; locked = lock mem; cursor = descr_words } in
        write_descr t ~epoch ~generation;
        Ok t

(* Named create holds the same lock as [recover] until the descriptor
   (including this process's pid) is stored. Otherwise a peer can observe
   magic 0 and unlink the object out from under a live creator. flock is
   not recursive, so [recover] calls [create_unlocked] while it already
   holds the lock. *)
let create ?(name = "") ?(addr = 0n) ?(epoch = self_pid ()) ?(generation = 1)
    ~words () =
  if name = "" then create_unlocked ~name ~addr ~epoch ~generation ~words ()
  else
    let fd = session_lock name in
    if fd < 0 then Error Map_failed
    else
      let result = create_unlocked ~name ~addr ~epoch ~generation ~words () in
      session_unlock fd;
      result

let reject mem err =
  unmap_raw mem;
  Error err

let attach ~name ?(addr = 0n) ~words () =
  if name = "" || words < descr_words then Error Too_small
  else
    match map name words false addr with
    | Error e -> Error e
    | Ok mem ->
        let mag = load_int mem d_magic in
        if mag = 0 then reject mem Uninitialized
        else if mag <> magic then reject mem Bad_magic
        else
          let ver = load_int mem d_version in
          let sz = load_int mem d_words in
          if ver <> layout_version then reject mem Bad_version
          else if sz <> words then reject mem Size_mismatch
          else Ok { mem; locked = lock mem; cursor = descr_words }

let unmap t = unmap_raw t.mem

let reclaim ?(addr = 0n) ~name ~epoch ~generation ~words () =
  let code, mem = reclaim_raw name words addr in
  match error_of_code code with
  | Some e -> Error e
  | None ->
      let t = { mem; locked = lock mem; cursor = descr_words } in
      write_descr t ~epoch ~generation;
      Ok t

let recover ?(addr = 0n) ~name ~epoch ~words () =
  if name = "" then Error Range
  else
    let fd = session_lock name in
    if fd < 0 then Error Map_failed
    else
      (* Re-read under the lock. A creator that is still alive — even one
         that has not published yet — owns the name. Only a dead epoch or
         an unfinished (magic 0) object is replaced, and the unlink happens
         before the lock is dropped. *)
      let result =
        match attach ~name ~addr ~words () with
        | Error Not_found ->
            create_unlocked ~name ~addr ~epoch ~words ()
        | Error Uninitialized ->
            reclaim ~addr ~name ~epoch ~generation:1 ~words ()
        | Error (Bad_magic | Bad_version | Too_small | Size_mismatch) as e -> e
        | Error e -> Error e
        | Ok old ->
            let creator = load_int old.mem d_epoch in
            let gen = load_int old.mem d_generation in
            let live = pid_alive creator in
            unmap old;
            if live then Error Busy
            else
              let generation = if gen <= 0 || gen = max_int then 1 else gen + 1 in
              reclaim ~addr ~name ~epoch ~generation ~words ()
      in
      session_unlock fd;
      result

let publish t = store_int t.mem d_state state_ready
let is_ready t = load_int t.mem d_state = state_ready
let epoch t = load_int t.mem d_epoch
let generation t = load_int t.mem d_generation
let creator_alive t = pid_alive (epoch t)

let slice t n =
  let total = dim_words t.mem in
  if n < 0 || t.cursor < 0 || t.cursor > total || n > total - t.cursor then
    Error Exhausted
  else begin
    let s = Bigarray.Array1.sub t.mem t.cursor n in
    t.cursor <- t.cursor + n;
    Ok s
  end

let channel_create () =
  if not (have_qnx_ipc ()) then Error `unavailable
  else
    let rc = channel_create_raw () in
    if rc >= 0 then Ok rc else Error (`os (-rc))
