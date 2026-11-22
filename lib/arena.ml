type t = {
  s : Region.words;
  capacity : int;
  node_words : int;
  flags_base : int;
  nodes_base : int;
}

type error = Bad_magic | Bad_version | Bad_size | Truncated

let nil = -1
let header_words = 8
let magic = 0x41524E31 (* "ARN1" *)
let version = 1

let f_magic = 0
let f_version = 1
let f_capacity = 2
let f_node_words = 3
let f_free = 4
let f_in_use = 5
let f_flags = 6
let f_nodes = 7

(* Head word: bits 0–30 index (all-ones = empty), bits 31–61 tag.
   The tag makes the CAS ABA-safe for 2^31 successful pushes. *)
let idx_bits = 31
let idx_mask = (1 lsl idx_bits) - 1

let pack tag idx =
  let u = if idx < 0 then idx_mask else idx land idx_mask in
  ((tag land idx_mask) lsl idx_bits) lor u

(* Ints, not a pair: a tuple would allocate on every alloc/free. *)
let tag_of w = (w lsr idx_bits) land idx_mask

let idx_of w =
  let u = w land idx_mask in
  if u = idx_mask then -1 else u

let words_needed ~capacity ~node_words =
  if capacity <= 0 || node_words <= 0 || capacity >= idx_mask then 0
  else if node_words > max_int - 1 then 0
  else
    let stride = node_words + 1 in
    if capacity > (max_int - header_words) / stride then 0
    else header_words + (capacity * stride)

let node_off t i = t.nodes_base + (i * t.node_words)
let flag_off t i = t.flags_base + i
let field_off t i f = node_off t i + f

let capacity t = t.capacity
let node_words t = t.node_words
let in_use t = Region.load_int t.s f_in_use

let get_int t i f = Region.load_relaxed t.s (field_off t i f)
let set_int t i f v = Region.store_relaxed t.s (field_off t i f) v
let store_int64 t i f v = Region.store_int64 t.s (field_off t i f) v
let cmp_int64 t i f k = Region.cmp_int64 t.s (field_off t i f) k
let cmp_fields t i f j g =
  Region.cmp_words t.s (field_off t i f) (field_off t j g)
let store_mix t i f k = Region.store_mix t.s (field_off t i f) k
let copy_node t dst src =
  Region.copy_words t.s (node_off t dst) t.s (node_off t src) t.node_words

let create s ~capacity ~node_words =
  let need = words_needed ~capacity ~node_words in
  if need = 0 || need > Region.dim_words s then Error Bad_size
    else begin
      let flags_base = header_words in
      let nodes_base = header_words + capacity in
      for i = 0 to capacity - 1 do
        let next = if i = capacity - 1 then -1 else i + 1 in
        Region.store_relaxed s (nodes_base + (i * node_words)) next;
        Region.store_relaxed s (flags_base + i) 0
      done;
      Region.store_relaxed s f_version version;
      Region.store_relaxed s f_capacity capacity;
      Region.store_relaxed s f_node_words node_words;
      Region.store_relaxed s f_in_use 0;
      Region.store_relaxed s f_flags flags_base;
      Region.store_relaxed s f_nodes nodes_base;
      Region.store_int s f_free (pack 0 0);
      Region.store_int s f_magic magic;
      Ok { s; capacity; node_words; flags_base; nodes_base }
    end

let attach s =
  if Region.dim_words s < header_words then Error Truncated
  else if Region.load_int s f_magic <> magic then Error Bad_magic
  else if Region.load_int s f_version <> version then Error Bad_version
  else
    let capacity = Region.load_int s f_capacity in
    let node_words = Region.load_int s f_node_words in
    let flags_base = Region.load_int s f_flags in
    let nodes_base = Region.load_int s f_nodes in
    let need = words_needed ~capacity ~node_words in
    if need = 0 then Error Bad_size
    else if need > Region.dim_words s then Error Truncated
    else if flags_base <> header_words || nodes_base <> header_words + capacity
    then Error Bad_size
    else Ok { s; capacity; node_words; flags_base; nodes_base }

let rec alloc t =
  let w = Region.load_int t.s f_free in
  let i = idx_of w in
  if i < 0 then nil
  else
    let next = Region.load_relaxed t.s (node_off t i) in
    let tag' = (tag_of w + 1) land idx_mask in
    if Region.cas_int t.s f_free w (pack tag' next) then begin
      Region.store_relaxed t.s (flag_off t i) 1;
      ignore (Region.fetch_add_int t.s f_in_use 1);
      i
    end else alloc t

let alloc_res t =
  let i = alloc t in
  if i < 0 then Error `exhausted else Ok i

let rec push_free t i =
  let w = Region.load_int t.s f_free in
  Region.store_relaxed t.s (node_off t i) (idx_of w);
  let tag' = (tag_of w + 1) land idx_mask in
  if Region.cas_int t.s f_free w (pack tag' i) then
    ignore (Region.fetch_add_int t.s f_in_use (-1))
  else push_free t i

let free t i =
  if i < 0 || i >= t.capacity then false
  else if not (Region.cas_int t.s (flag_off t i) 1 0) then false
  else begin
    push_free t i;
    true
  end
