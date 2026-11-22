(** Fixed-peer version vector. One monotone counter per peer, each on its
    own 64-byte line so peers pinned to different cores do not false-share.

    The resident layout is padded. [compare] and [merge] take a dense
    vector of [n] words — the wire format. [pack] writes the resident
    counters into that dense shape.

    [tick] is an atomic fetch-add on the local component. [merge] is a
    CAS loop that stores [max] and retries when the word changed, so a
    concurrent tick cannot be overwritten by a stale snapshot (the clock
    does not go backwards). A tick that linearizes after a merge correctly
    yields [max + 1]; that is a later event, not inflation.

    [tick], [get], [compare], and [merge] allocate nothing. Counters are
    63-bit ints. *)

type t
type order = Equal | Before | After | Concurrent
type error = Bad_peers

val line_words : int
val words_needed : peers:int -> int
val init : Region.words -> peers:int -> me:int -> (t, error) result
val attach : Region.words -> me:int -> (t, error) result
val tick : t -> unit
val get : t -> int -> int
val compare : t -> Region.words -> order
val merge : t -> Region.words -> unit
val pack : t -> Region.words -> bool
