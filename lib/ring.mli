(** Bounded single-producer / single-consumer ring.

    Layout within the slice (int64 indexes):
    {[
      0     tail   — slots ever pushed, producer only, its own cache line
      1–7   pad
      8     head   — slots ever popped, consumer only, next cache line
      9     capacity
      10    slot width
      11…   capacity * width payload words
    ]}

    The producer release-stores [tail] after the payload copy; the consumer
    acquire-loads [tail] before reading a slot, and release-stores [head]
    after. That is the only synchronization the ring needs.

    Counters are 63-bit ints (see [Region.load_int]). [push] and [pop] copy
    payload with a C [memmove] and allocate nothing on the success path.
    [attach] rejects a zero or non-positive capacity or width so a
    not-yet-initialized slice fails here instead of dividing by zero. *)

type t
type error = Bad_geometry

val header_words : int
val words_needed : slots:int -> width:int -> int
val init : Region.words -> slots:int -> width:int -> (t, error) result
val attach : Region.words -> (t, error) result
val push : t -> Region.words -> bool
val pop : t -> Region.words -> bool
val occupancy : t -> int
