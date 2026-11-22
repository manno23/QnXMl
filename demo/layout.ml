(** Shared-memory layout for the two-process demo.

    The cross-process contract is the region descriptor (magic, version,
    size, ready flag, epoch, generation — see [Region]) followed by slices
    carved in the same order:

    - header: producer pid, producer chid, consumer pid, consumer chid
    - ring: [Ring.words_needed] words

    Ready is the region descriptor's state word, release-stored by the
    producer only after the ring and the producer's pid/chid are published.
    A zeroed or foreign object fails [Region.attach] instead of being
    treated as a live session. *)

let shm_name = "/qnxml_demo"

let slots = 64
let width = 4

let header_words = 8
let producer_pid = 0
let producer_chid = 1
let consumer_pid = 2
let consumer_chid = 3
(* 1 while the consumer may be blocked in MsgReceive. Release-stored by the
   consumer before it rechecks the ring; the producer CAS-es it back to 0
   and pulses. See [Wake.arm]. *)
let consumer_asleep = 4

let total_words =
  Region.descr_words + header_words + Ring.words_needed ~slots ~width

let ctl_words = 4

let pulse_data_ready = 1
let pulse_disconnect = (-33) land 0xFF
let pulse_code = Region.pulse_code

let producer_prio = 30
let consumer_prio = 31
let producer_cpu = 0
let consumer_cpu = 1

let sentinel = -1
let handshake_timeout = 10.0

let die msg =
  prerr_endline msg;
  exit 1

let must_slice r n =
  match Region.slice r n with
  | Ok s -> s
  | Error e -> die ("slice: " ^ Region.error_to_string e)

let private_slice n =
  match Region.create ~words:(Region.descr_words + n) () with
  | Ok r -> must_slice r n
  | Error e -> die ("private region: " ^ Region.error_to_string e)
