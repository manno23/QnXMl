(** Implicit-heap Merkle mixer over [leaves] (any positive count; the
    slice is [2 * leaves] words). Leaves occupy indexes [leaves .. 2*leaves-1].

    [update] runs entirely in C: splitmix the leaf, rehash the path, and
    release-store the root (word 1) last. [root] acquire-loads that word.
    That publishes the digest. A [proof] walks children after the acquire
    and is only a consistent snapshot while the writer is quiescent; a
    concurrent [update] can change a child the walk has not yet read.
    Single writer.

    The mixer detects divergence between trusting peers. It is not a
    collision-resistant hash.

    [update] allocates nothing. [root], [proof], and [verify] box int64s
    and are not on the steady-state budget. *)

type t
type error = Bad_leaves

val words_needed : leaves:int -> int
val init : Region.words -> leaves:int -> (t, error) result
val update : t -> int -> int64 -> unit
val root : t -> int64
val proof : t -> int -> (int * int64) list
val verify : leaf_value:int64 -> proof:(int * int64) list -> expected_root:int64 -> bool
