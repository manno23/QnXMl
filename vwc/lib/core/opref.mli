(* VWC-HDL-001: OpaqueRef is a 128-bit value comprising
   region_id (u32), generation (u32), offset (u32), writer_op_seq (u32).
   VWC-SYS-002: processes exchange memory references exclusively as
   OpaqueRefs; a virtual address never crosses a process boundary.
   VWC-SHM-004: all intra-Region references are Region-relative offsets;
   offset 0 encodes null. *)

type t = {
  region_id : int32;      (* u32: identifies the Region (kernel shm object) *)
  generation : int32;     (* u32: bumped on every reclamation/recycling *)
  offset : int32;         (* u32: region-relative byte offset; 0 = null *)
  writer_op_seq : int32;  (* u32: last op sequence this handle was written under *)
}

val null : t
val is_null : t -> bool

(* Pack/unpack to/from the 128-bit wire layout (two int64s), which is the
   only representation that may cross a process boundary (VWC-SYS-002). *)
val to_int64_pair : t -> int64 * int64
val of_int64_pair : int64 * int64 -> t

val compare : t -> t -> int
val equal : t -> t -> bool
val pp : Format.formatter -> t -> unit
