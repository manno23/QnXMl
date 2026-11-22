(* Node: key | value | prio | left | right. Priority is splitmix(key). *)

let k_ = 0 and v_ = 1 and p_ = 2 and l_ = 3 and r_ = 4
let node_words = 5
let nil = -1

let magic = 0x504D4150 (* "PMAP" *)
let version_magic = 1
let header = 16
let slot_words = 4

let s_magic = 0
let s_version = 1
let s_retention = 2
let s_capacity = 3
let s_next = 4
let s_log = 7
(* One release-published word: low 31 bits = newest slot, high bits = live
   count. Readers acquire-load it once so they never see a newest index
   paired with a stale live count. *)
let s_window = 6
let s_alloc = 9 (* intrusive stack of nodes allocated by the in-flight set *)
let win_mask = (1 lsl 31) - 1
let pack_win newest live = (live lsl 31) lor (newest land win_mask)
let win_newest w = w land win_mask
let win_live w = w lsr 31

type t = {
  a : Arena.t;
  meta : Region.words;
  retention : int;
  capacity : int;
  slots : int;
  repl : int;
}

type error = Bad_magic | Bad_version | Bad_size | Truncated

let words_needed ~retention ~capacity =
  if retention < 2 || capacity <= 0 then 0
  else if retention > win_mask || capacity > win_mask then 0
  else if capacity > max_int - header then 0
  else if retention > (max_int - header - capacity) / slot_words then 0
  else header + (retention * slot_words) + capacity

let slot_base t slot = t.slots + (slot * slot_words)

let create a meta ~retention =
  let capacity = Arena.capacity a in
  let need = words_needed ~retention ~capacity in
  if need = 0 || Arena.node_words a <> node_words then Error Bad_size
  else if need > Region.dim_words meta then Error Bad_size
  else begin
    let slots = header in
    let repl = header + (retention * slot_words) in
    for i = 0 to capacity - 1 do
      Region.store_relaxed meta (repl + i) nil
    done;
    Region.store_relaxed meta slots 0;
    Region.store_relaxed meta (slots + 1) nil;
    Region.store_relaxed meta (slots + 2) nil;
    Region.store_relaxed meta s_version version_magic;
    Region.store_relaxed meta s_retention retention;
    Region.store_relaxed meta s_capacity capacity;
    Region.store_relaxed meta s_next 1;
    Region.store_relaxed meta s_log nil;
    Region.store_int meta s_window (pack_win 0 1);
    Region.store_relaxed meta s_alloc nil;
    Region.store_int meta s_magic magic;
    Ok { a; meta; retention; capacity; slots; repl }
  end

let attach a meta =
  if Region.dim_words meta < header then Error Truncated
  else if Region.load_int meta s_magic <> magic then Error Bad_magic
  else if Region.load_int meta s_version <> version_magic then Error Bad_version
  else
    let retention = Region.load_int meta s_retention in
    let capacity = Region.load_int meta s_capacity in
    let need = words_needed ~retention ~capacity in
    if need = 0 || capacity <> Arena.capacity a || Arena.node_words a <> node_words
    then Error Bad_size
    else if need > Region.dim_words meta then Error Truncated
    else
      Ok {
        a;
        meta;
        retention;
        capacity;
        slots = header;
        repl = header + (retention * slot_words);
      }

(* New nodes of this [set] are stacked through [repl.(i)], which the copy
   log does not use for a node until a later version copies it. On failure
   the stack is freed; on success it is abandoned and the nodes stay in
   the new tree. *)
let push_new t i =
  let head = Region.load_relaxed t.meta s_alloc in
  Region.store_relaxed t.meta (t.repl + i) head;
  Region.store_relaxed t.meta s_alloc i

let rec rollback t fuel =
  if fuel = 0 then ()
  else
    let i = Region.load_relaxed t.meta s_alloc in
    if i < 0 then ()
    else
      let next = Region.load_relaxed t.meta (t.repl + i) in
      Region.store_relaxed t.meta s_alloc next;
      ignore (Arena.free t.a i);
      rollback t (fuel - 1)

let mk t key value left right =
  let i = Arena.alloc t.a in
  if i < 0 then nil
  else begin
    push_new t i;
    Arena.store_int64 t.a i k_ key;
    Arena.store_int64 t.a i v_ value;
    Arena.store_mix t.a i p_ key;
    Arena.set_int t.a i l_ left;
    Arena.set_int t.a i r_ right;
    i
  end

let dup t node =
  let j = Arena.alloc t.a in
  if j < 0 then nil
  else begin
    push_new t j;
    if not (Arena.copy_node t.a j node) then nil
    else begin
      let head = Region.load_relaxed t.meta s_log in
      Region.store_relaxed t.meta (t.repl + node) head;
      Region.store_relaxed t.meta s_log node;
      j
    end
  end

let rec ins t node key value =
  if node < 0 then mk t key value nil nil
  else
    let c = Arena.cmp_int64 t.a node k_ key in
    if c = 0 then
      let n' = dup t node in
      if n' < 0 then nil
      else begin
        Arena.store_int64 t.a n' v_ value;
        n'
      end
    else if c > 0 then
      let l' = ins t (Arena.get_int t.a node l_) key value in
      if l' < 0 then nil
      else
        let n' = dup t node in
        if n' < 0 then nil
        else begin
          Arena.set_int t.a n' l_ l';
          if Arena.cmp_fields t.a l' p_ n' p_ > 0 then begin
            Arena.set_int t.a n' l_ (Arena.get_int t.a l' r_);
            Arena.set_int t.a l' r_ n';
            l'
          end else n'
        end
    else
      let r' = ins t (Arena.get_int t.a node r_) key value in
      if r' < 0 then nil
      else
        let n' = dup t node in
        if n' < 0 then nil
        else begin
          Arena.set_int t.a n' r_ r';
          if Arena.cmp_fields t.a r' p_ n' p_ > 0 then begin
            Arena.set_int t.a n' r_ (Arena.get_int t.a r' l_);
            Arena.set_int t.a r' l_ n';
            r'
          end else n'
        end

let root_at t slot = Region.load_relaxed t.meta (slot_base t slot + 1)

let rec scan_version t version slot left =
  if left = 0 then -2
  else
    let b = slot_base t slot in
    let id = Region.load_relaxed t.meta b in
    if id = version then Region.load_relaxed t.meta (b + 1)
    else
      let prev = if slot = 0 then t.retention - 1 else slot - 1 in
      scan_version t version prev (left - 1)

let root_for t version =
  let w = Region.load_int t.meta s_window in
  let newest = win_newest w in
  if version < 0 then root_at t newest
  else scan_version t version newest (win_live w)

let rec find_node t node key =
  if node < 0 then nil
  else
    let c = Arena.cmp_int64 t.a node k_ key in
    if c = 0 then node
    else if c > 0 then find_node t (Arena.get_int t.a node l_) key
    else find_node t (Arena.get_int t.a node r_) key

let version_arg = function None -> -1 | Some v -> v

let mem ?version t key =
  let root = root_for t (version_arg version) in
  root <> -2 && find_node t root key >= 0

let find_eq ?version t key value =
  let root = root_for t (version_arg version) in
  if root = -2 then false
  else
    let n = find_node t root key in
    n >= 0 && Arena.cmp_int64 t.a n v_ value = 0

let has_version t id = id >= 0 && root_for t id <> -2

let live_count t = win_live (Region.load_int t.meta s_window)
let nodes_in_use t = Arena.in_use t.a

let rec free_log t n fuel =
  if n < 0 || fuel = 0 then ()
  else
    let next = Region.load_relaxed t.meta (t.repl + n) in
    ignore (Arena.free t.a n);
    free_log t next (fuel - 1)

let set t key value =
  Region.store_relaxed t.meta s_log nil;
  Region.store_relaxed t.meta s_alloc nil;
  let root0 = root_for t (-1) in
  let root' = ins t root0 key value in
  if root' < 0 then begin
    rollback t t.capacity;
    nil
  end else
    let id = Region.fetch_add_int t.meta s_next 1 in
    let w = Region.load_relaxed t.meta s_window in
    let newest = win_newest w in
    let live0 = win_live w in
    (* Retire before publishing. The window word is stored once, after the
       new slot body, so a reader cannot observe the new slot index with
       the old live count. *)
    let live =
      if live0 = t.retention && live0 > 1 then begin
        let oldest = (newest - live0 + 1 + t.retention) mod t.retention in
        let succ = (oldest + 1) mod t.retention in
        let repl = Region.load_relaxed t.meta (slot_base t succ + 2) in
        free_log t repl t.capacity;
        live0 - 1
      end else live0
    in
    let slot = (newest + 1) mod t.retention in
    let repl = Region.load_relaxed t.meta s_log in
    let b = slot_base t slot in
    Region.store_relaxed t.meta b id;
    Region.store_relaxed t.meta (b + 1) root';
    Region.store_relaxed t.meta (b + 2) repl;
    Region.store_int t.meta s_window (pack_win slot (live + 1));
    id
