(* VWC-RGN-001: each Grant contains, in order: a header (state word, seal
   record, Manager-owned watermark slot, generation echo), a File Table, a
   Write Log arena, and an optional trailing guard page.
   VWC-RGN-003: the File Table binds each slot index to the file's identity
   and to the base recipe reference resolved from the Head snapshot.
   VWC-RGN-005: a Grant traverses only ALLOCATED -> ACTIVE -> SEALED ->
   (PERSISTED | ABORTED) -> UNMAPPED -> RECLAIMED.
   VWC-RGN-006: exactly one Seal per Grant; writes after Seal target only a
   standby Grant.
   VWC-RGN-007: the Manager-owned watermark slot is writable only by the
   Manager and re-armable while ACTIVE.
   VWC-RGN-008: the Client evaluates (allocation cursor >= watermark) on
   every Write Log allocation and initiates Seal when it becomes true. *)

type state =
  | Allocated
  | Active
  | Sealed
  | Persisted
  | Aborted
  | Unmapped
  | Reclaimed

val state_of_int : int -> state
val int_of_state : state -> int
val state_to_string : state -> string

(* Grant layout constants (offsets within the region, in words). *)
val hdr_state : int
val hdr_seal_log_end : int   (* seal publishes (log_end, op_seq) — LOG-005 *)
val hdr_seal_op_seq : int
val hdr_watermark : int
val hdr_generation_echo : int
val hdr_words : int

(* Transition validator: returns Ok () if [next] is a legal successor of
   [cur] per RGN-005, Error otherwise. *)
val transition : state -> state -> (unit, string) result

(* File table slot: file identity + base recipe reference (RGN-003). *)
type file_slot = {
  slot : int;
  file_id : int64;
  base_recipe : Opref.t;
}
