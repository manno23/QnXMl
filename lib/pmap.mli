(** Persistent int64-to-int64 treap. Nodes come from an [Arena]; the
    version window and the per-version copy-log live in a second slice, so
    a peer can [attach] and see the same history.

    [set] path-copies. Nodes copied while building version [v+1] are
    referenced only by versions ≤ [v], so when [v] is the oldest retained
    version and retires, that log is exactly the garbage set. The log is
    an intrusive index list in the meta slice — not an OCaml list — and
    [set] / [find_eq] / [mem] allocate nothing.

    Concurrency: one writer. [set] release-stores the newest-slot index
    after the new root is fully written; readers acquire-load it. A reader
    must not hold a root across a concurrent [set] that retires that
    version (no epoch reclamation yet). Same-thread [find] after [set]
    returns is safe.

    Keys and values stay in the slab. Pass int64s the caller already owns
    (a literal or a value allocated outside the loop); the hot path does
    not box a fresh one. *)

type t
type error = Bad_magic | Bad_version | Bad_size | Truncated

val node_words : int
val words_needed : retention:int -> capacity:int -> int
val create : Arena.t -> Region.words -> retention:int -> (t, error) result
val attach : Arena.t -> Region.words -> (t, error) result

val set : t -> int64 -> int64 -> int
(** New version id, or [-1] if the arena cannot supply the path. *)

val find_eq : ?version:int -> t -> int64 -> int64 -> bool
val mem : ?version:int -> t -> int64 -> bool
val has_version : t -> int -> bool
val live_count : t -> int
val nodes_in_use : t -> int
