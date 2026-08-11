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

type t = { mem : words; locked : bool; mutable cursor : int }

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
