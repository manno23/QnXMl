(** Fixed pool of fixed-size nodes. The free list, the in-use count, and
    a per-node allocated flag live in the slice, so two processes that
    [attach] the same arena share one allocator.

    Handles are node indexes. [-1] ([nil]) is exhaustion — a bare int, not
    an [Ok] block, because a result would allocate on every successful
    alloc and break the steady-state budget. [alloc_res] is the same
    operation for callers that want a [result] and can afford the box.

    [free] is a CAS on the allocated flag, so a double-free returns false
    instead of corrupting the intrusive list. The list head is a tagged
    (generation, index) word updated with CAS; the tag is 31 bits.

    Single-writer payload, multi-allocator free list. Node words themselves
    are relaxed stores published by whatever structure release-stores a
    root that points at them (see [Pmap]). *)

type t
type error = Bad_magic | Bad_version | Bad_size | Truncated

val nil : int
val header_words : int
val words_needed : capacity:int -> node_words:int -> int
val create :
  Region.words -> capacity:int -> node_words:int -> (t, error) result
val attach : Region.words -> (t, error) result
val alloc : t -> int
val alloc_res : t -> (int, [ `exhausted ]) result
val free : t -> int -> bool
val in_use : t -> int
val capacity : t -> int
val node_words : t -> int
val get_int : t -> int -> int -> int
val set_int : t -> int -> int -> int -> unit
val store_int64 : t -> int -> int -> int64 -> unit
val cmp_int64 : t -> int -> int -> int64 -> int
val cmp_fields : t -> int -> int -> int -> int -> int
val store_mix : t -> int -> int -> int64 -> unit
val copy_node : t -> int -> int -> bool
