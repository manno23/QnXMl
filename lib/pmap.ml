(* Persistent int64->int64 map: a treap with path copying, nodes pooled in
   an Arena, versions kept in a sliding window.

   Persistence: [set] copies the root-to-key path (expected O(log n) fresh
   nodes), so every retained version's tree is intact and lookups against
   old versions cost nothing extra.

   Retirement (the part that reconciles persistence with preallocation):
   while building version v+1 we LOG the index of every node we copied
   from — those nodes belong to versions <= v and to no newer version, so
   the moment v is the oldest retained version and retires, v+1's log is
   exactly the garbage set. Freeing it is O(nodes actually replaced), not
   O(tree). Bounded history + bounded arena = bounded memory, by
   construction rather than by GC.

   Node layout (5 words): 0 key | 1 value | 2 prio | 3 left | 4 right.
   Treap priority = hash(key): deterministic, expected-balanced, no RNG
   state to manage. *)

type version = {
  id : int;
  root : int;
  replaced : int list;   (* nodes this version copied over *)
}

type t = {
  a : Arena.t;
  mutable versions : version list;  (* newest first *)
  mutable next_id : int;
  retention : int;
}

let nil = Arena.nil
let k_ = 0 and v_ = 1 and p_ = 2 and l_ = 3 and r_ = 4

let node_words = 5

(* splitmix64 finalizer as priority hash *)
let prio_of key =
  let open Int64 in
  let z = add key 0x9E3779B97F4A7C15L in
  let z = mul (logxor z (shift_right_logical z 30)) 0xBF58476D1CE4E5B9L in
  let z = mul (logxor z (shift_right_logical z 27)) 0x94D049BB133111EBL in
  logxor z (shift_right_logical z 31)

let create arena ~retention =
  { a = arena; versions = [ { id = 0; root = nil; replaced = [] } ];
    next_id = 1; retention }

let mk t key value left right =
  let i = Arena.alloc t.a in
  Arena.set t.a i k_ key;
  Arena.set t.a i v_ value;
  Arena.set t.a i p_ (prio_of key);
  Arena.seti t.a i l_ left;
  Arena.seti t.a i r_ right;
  i

(* copy an existing node; caller mutates the fresh copy freely *)
let dup t i log =
  let j = Arena.alloc t.a in
  for f = 0 to node_words - 1 do Arena.set t.a j f (Arena.get t.a i f) done;
  log := i :: !log;
  j

(* Insert with path copying + treap rotations. Every node we touch is a
   fresh copy, so rotations mutate only nodes invisible to old versions. *)
let rec ins t node key value log =
  if node = nil then mk t key value nil nil
  else begin
    let nk = Arena.get t.a node k_ in
    if key = nk then begin
      let n' = dup t node log in
      Arena.set t.a n' v_ value; n'
    end else if key < nk then begin
      let l' = ins t (Arena.geti t.a node l_) key value log in
      let n' = dup t node log in
      Arena.seti t.a n' l_ l';
      if Arena.get t.a l' p_ > Arena.get t.a n' p_ then begin
        (* rotate right: l' becomes parent *)
        Arena.seti t.a n' l_ (Arena.geti t.a l' r_);
        Arena.seti t.a l' r_ n';
        l'
      end else n'
    end else begin
      let r' = ins t (Arena.geti t.a node r_) key value log in
      let n' = dup t node log in
      Arena.seti t.a n' r_ r';
      if Arena.get t.a r' p_ > Arena.get t.a n' p_ then begin
        Arena.seti t.a n' r_ (Arena.geti t.a r' l_);
        Arena.seti t.a r' l_ n';
        r'
      end else n'
    end
  end

let newest t = List.hd t.versions

let retire_oldest t =
  match List.rev t.versions with
  | oldest :: rest_rev when rest_rev <> [] ->
      let successor = List.hd rest_rev in
      (* nodes copied over while making [successor] are referenced only by
         versions <= oldest — all gone after this call: free them *)
      List.iter (Arena.free t.a) successor.replaced;
      t.versions <- List.rev rest_rev;
      ignore oldest
  | _ -> ()

(* [set] creates and publishes a new version; returns its id. *)
let set t key value =
  let log = ref [] in
  let root' = ins t (newest t).root key value log in
  let id = t.next_id in
  t.next_id <- id + 1;
  t.versions <- { id; root = root'; replaced = !log } :: t.versions;
  if List.length t.versions > t.retention then retire_oldest t;
  id

let rec find_node t node key =
  if node = nil then None
  else
    let nk = Arena.get t.a node k_ in
    if key = nk then Some (Arena.get t.a node v_)
    else if key < nk then find_node t (Arena.geti t.a node l_) key
    else find_node t (Arena.geti t.a node r_) key

let find ?version t key =
  let v =
    match version with
    | None -> newest t
    | Some id ->
        (try List.find (fun v -> v.id = id) t.versions
         with Not_found -> failwith "version retired")
  in
  find_node t v.root key

let live_versions t = List.map (fun v -> v.id) t.versions
let nodes_in_use t = t.a.Arena.in_use
