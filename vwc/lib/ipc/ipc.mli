(* VWC-IPC-001: all Client-initiated operations use the synchronous
   send/receive/reply pattern; the Client remains reply-blocked until the
   Manager replies.
   VWC-IPC-002: Manager-initiated notifications use pulses (doorbells) only
   and carry no Region contents.
   VWC-IPC-003: the Manager services commit requests in per-channel receive
   order; this order defines the total order of operations.

   Message catalog (VWC-IPC table):
     010 MSG_ATTACH         C->M credentials -> session_id, snapshot fd
     011 MSG_ATTACH_REGION  C->M region_id -> fd, generation, length
     020 MSG_ACQUIRE        C->M paths[], size_hint -> Grant fd, OpaqueRef,
                            descriptor, standby fd (opt)
     021 MSG_OPEN_MORE      C->M OpaqueRef, paths[] -> new slot indices
     030 MSG_COMMIT         C->M OpaqueRef, base_op_seq, meta ->
                            COMMITTED{op_id, op_seq, standby fd} |
                            CONFLICT{slots[]} | FAULT{code}
     031 MSG_ABORT          C->M OpaqueRef -> ok
     040 MSG_DETACH         C->M session_id -> ok
     090 PULSE_HEAD         M->C new head_seq
     091 PULSE_FLUSH        M->C request Seal at next boundary *)

type msg_id = int

val msg_attach : msg_id          (* 010 *)
val msg_attach_region : msg_id   (* 011 *)
val msg_acquire : msg_id         (* 020 *)
val msg_open_more : msg_id       (* 021 *)
val msg_commit : msg_id          (* 030 *)
val msg_abort : msg_id           (* 031 *)
val msg_detach : msg_id          (* 040 *)
val pulse_head : msg_id          (* 090 *)
val pulse_flush : msg_id         (* 091 *)

(* Wire envelope: every message carries (id, seq, payload bytes). *)
type envelope = {
  id : msg_id;
  seq : int64;
  payload : Bytes.t;
}

(* Reply payloads *)
type commit_reply =
  | Committed of { op_id : int64; op_seq : int; standby_fd : int option }
  | Conflict of { slots : int list; head_op_seq : int }
  | Fault of { code : int }

val encode_envelope : envelope -> Bytes.t
val decode_envelope : Bytes.t -> envelope option
val encode_commit_reply : commit_reply -> Bytes.t
val decode_commit_reply : Bytes.t -> commit_reply
