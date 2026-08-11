(* Shared-memory layout for the two-process demo. Producer and consumer both
   carve the region in this order, so their word indices agree — the whole
   cross-process contract is this module.

   Slice order (carve order is the contract; bump header_words only with the
   magic, which gates consumer attach):
     header:  magic, producer pid, producer chid, consumer pid, consumer chid
     ring:    Ring.words_needed words (head/tail padded per SPEC A.5) *)

let shm_name = "/qnxml_demo"

let slots = 64
let width = 4 (* words per message: seq, payload, 2 spare *)

(* Word 0 of the region: producer release-stores this AFTER Ring.init AND
   after publishing its own pid/chid (words 1–2), so an early-attaching
   consumer never sees a half-initialized ring or a missing control plane.
   Words 1–2: producer pid + channel id. Words 3–4: consumer pid + channel
   id — the producer waits for word 3 (the "consumer registered" flag),
   release-ordered after word 4 (the consumer's chid), so a data-before-flag
   publish. *)
let magic = 0x514E584D4C64656DL (* "QNXMLdem" *)

let header_words = 5
let total_words = header_words + Ring.words_needed ~slots ~width

(* Control-channel staging: a pulse is struct _pulse = 16 bytes = 2 words;
   the status message is 2 words; the ack reply is 1 word. 4 words gives
   headroom and a fixed buffer for MsgReceive's validate-length check. *)
let ctl_words = 4

(* Pulse codes must live in _PULSE_CODE_MINAVAIL..MAXAVAIL (0..127).
   _PULSE_CODE_DISCONNECT = -33 (kernel-reserved, delivered on client death
   thanks to _NTO_CHF_DISCONNECT). struct _pulse: type u16, subtype u16,
   code i8 at byte offset 4 — as an int64 word (LE), code = bits 32..39. *)
let pulse_data_ready = 1
let pulse_disconnect = (-33) land 0xFF
let pulse_code buf =
  Int64.to_int
    (Int64.logand (Int64.shift_right_logical buf.{0} 32) 0xFFL)

(* Scheduling map (SPEC B.1): SCHED_FIFO, priorities <= 63 so the
   unprivileged qnxuser needs no PROCMGR_AID_PRIORITY; BMP-style pinning
   so producer/consumer provably run on different cores. *)
let producer_prio = 30
let consumer_prio = 31
let producer_cpu = 0
let consumer_cpu = 1

(* seq value that marks end-of-stream; its payload word carries the
   producer's running checksum for the consumer to verify. *)
let sentinel = -1L
