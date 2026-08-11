(* Fixed-capacity pool of fixed-size nodes inside a region slice.
   Handles are ints (node indices), the cross-process-valid, GC-invisible
   replacement for pointers. Free list is intrusive: word 0 of a free node
   holds the next free index. Steady state allocates zero OCaml heap. *)

type t = {
  s : Region.words;
  node_words : int;
  capacity : int;
  mutable free_head : int;   (* -1 = exhausted *)
  mutable in_use : int;
}

let nil = -1

let words_needed ~capacity ~node_words = capacity * node_words

let create s ~capacity ~node_words =
  (* chain every node onto the free list, once, at init *)
  for i = 0 to capacity - 1 do
    s.{i * node_words} <- Int64.of_int (if i = capacity - 1 then nil else i + 1)
  done;
  { s; node_words; capacity; free_head = 0; in_use = 0 }

let alloc t =
  let i = t.free_head in
  if i = nil then failwith "arena exhausted: capacity was the preallocation contract";
  t.free_head <- Int64.to_int t.s.{i * t.node_words};
  t.in_use <- t.in_use + 1;
  i

let free t i =
  t.s.{i * t.node_words} <- Int64.of_int t.free_head;
  t.free_head <- i;
  t.in_use <- t.in_use - 1

(* field access on a node handle *)
let get t i f = t.s.{(i * t.node_words) + f}
let set t i f v = t.s.{(i * t.node_words) + f} <- v
let geti t i f = Int64.to_int (get t i f)
let seti t i f v = set t i f (Int64.of_int v)
