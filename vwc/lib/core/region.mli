(* VWC-SHM-001: the Manager creates every Region as a kernel object
   (memfd_create on Linux; shm object on QNX) and retains an open descriptor
   for its entire lifetime.
   VWC-SHM-003: Clients map Regions MAP_SHARED at an unspecified base and
   make no assumption of address equality across processes.
   VWC-SHM-006: cross-process visibility established solely by
   release-store/acquire-load pairs; no syscall required for visibility.
   VWC-RES-001: each attached process publishes, in a single-writer control
   slot, the oldest operation sequence it may still read. *)

(* A mapped shared-memory region. The backing store is a kernel object
   (fd retained by Manager on QNX/Linux); each process maps it at its own
   base. All references inside are offsets, resolved via this table. *)
type t

(* Create a new region (Manager side). Returns the region and the kernel
   descriptor/handle to hand to clients inside IPC replies (SHM-002). *)
val create : name:string -> bytes:int -> t
val handle : t -> int          (* fd / shm handle for SCM_RIGHTS delivery *)
val size : t -> int

(* Attach (Client side) from a handle received in an IPC reply. Maps
   MAP_SHARED at an unspecified base (SHM-003). *)
val attach : handle:int -> bytes:int -> t
val detach : t -> unit

(* Region table: resolve an OpaqueRef to a local pointer. Fails, without
   memory access, when generation differs (HDL-002). *)
val resolve : t -> Opref.t -> (int, [> `Stale | `Miss ]) result

(* Per-process region table: region_id -> (base, mapped_generation) *)
val register : t -> Opref.t -> unit
val lookup : t -> int32 -> (Opref.t, [> `Miss ]) result

(* Word accessors over the mapping (Bigarray-backed for zero-alloc). *)
val words : t -> (int64, Bigarray.int64_elt, Bigarray.c_layout) Bigarray.Array1.t

(* Publication pair (SHM-006): release-store / acquire-load on a word.
   Fences only; payload stores ordered by the release. *)
val store_rel : t -> int -> int64 -> unit
val load_acq : t -> int -> int64
