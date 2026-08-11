(* Shared-memory layout for the two-process demo. Producer and consumer both
   carve the region in this order, so their word indices agree — the whole
   cross-process contract is this module. *)

let shm_name = "/qnxml_demo"

let slots = 64
let width = 4 (* words per message: seq, payload, 2 spare *)

(* Word 0 of the region: producer release-stores this after Ring.init so an
   early-attaching consumer never sees a half-initialized ring. *)
let magic = 0x514E584D4C64656DL (* "QNXMLdem" *)

let header_words = 1
let total_words = header_words + Ring.words_needed ~slots ~width

(* seq value that marks end-of-stream; its payload word carries the
   producer's running checksum for the consumer to verify. *)
let sentinel = -1L
