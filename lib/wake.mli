(** Wakeups for the SPSC ring.

    [send] is a local debt: the caller sets [owed] and [send] pulses until
    one attempt returns 0. It does not by itself close the race with a
    consumer that sleeps after the occupancy check.

    [arm] is the cross-process protocol. The consumer release-stores 1 into
    a shared word, rechecks the ring, and only then blocks. The producer
    calls [arm] after a successful push. [Awake] means no sleeper was
    published (or the consumer already cleared the word). [Pulsed] means
    this caller won the CAS and the pulse landed. [Again] means the pulse
    returned an errno; the sleeper word is restored to 1. *)

val send : owed:bool ref -> pulse:(unit -> int) -> int

type attempt =
  | Awake
  | Pulsed
  | Again of int

val arm :
  load:(unit -> int) -> cas:(int -> int -> bool) -> pulse:(unit -> int) -> attempt
