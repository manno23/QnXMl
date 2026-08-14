(* VWC-LOG-001: Write Log records are appended strictly in modification
   order (temporal), independent of target file offsets.
   VWC-LOG-002: each record: magic, slot_idx, file_offset, length, monotonic
   seq, CRC32C over header+payload, payload bytes.
   VWC-LOG-003: for overlapping byte ranges within one Grant, the record
   with the greater seq supersedes.
   VWC-LOG-004: the Write Log is the sole authoritative content; any per-file
   index is advisory.
   VWC-LOG-006: a record failing CRC, and all records after it, are excluded
   from replay (torn-tail truncation). *)

type record = {
  magic : int32;
  slot_idx : int;
  file_offset : int64;
  length : int;
  seq : int;          (* monotonic per-Grant sequence *)
  crc : int32;        (* CRC32C over header + payload *)
  payload : string;
}

val magic : int32

(* Encode a record into its wire bytes (header + payload). *)
val encode : record -> Bytes.t

(* Decode; returns None on magic mismatch. CRC validation is separate so the
   caller can implement LOG-006 (truncate tail on bad CRC). *)
val decode : Bytes.t -> record option

(* CRC32C (Castagnoli) over a byte buffer. Implemented via the hardware
   crc32 instruction where available (aarch64), software fallback otherwise. *)
val crc32c : string -> int32
val crc32c_bytes : Bytes.t -> int32
