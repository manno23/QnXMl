type t = { s : Region.words; me : int; n : int }
type order = Equal | Before | After | Concurrent
type error = Bad_peers

let line_words = 8
let n_ix = 0
let component_ix i = line_words * (i + 1)
let words_needed ~peers =
  if peers <= 0 || peers >= max_int / line_words then 0
  else line_words * (peers + 1)

let init s ~peers ~me =
  let need = words_needed ~peers in
  if need = 0 || me < 0 || me >= peers then Error Bad_peers
  else if need > Region.dim_words s then Error Bad_peers
  else begin
    for i = 0 to peers - 1 do
      Region.store_relaxed s (component_ix i) 0
    done;
    Region.store_int s n_ix peers;
    Ok { s; me; n = peers }
  end

let attach s ~me =
  if Region.dim_words s <= n_ix then Error Bad_peers
  else
    let n = Region.load_int s n_ix in
    let need = words_needed ~peers:n in
    if need = 0 || me < 0 || me >= n then Error Bad_peers
    else if need > Region.dim_words s then Error Bad_peers
    else Ok { s; me; n }

let tick t = ignore (Region.fetch_add_int t.s (component_ix t.me) 1)

let get t i = Region.load_int t.s (component_ix i)

let rec cas_max s ix b =
  let a = Region.load_int s ix in
  if b <= a then ()
  else if Region.cas_int s ix a b then ()
  else cas_max s ix b

(* Top-level so the recursive calls are not closures. A [let rec] nested
   in [merge]/[compare] would allocate on every call. *)
let rec merge_from t other n i =
  if i = n then ()
  else begin
    cas_max t.s (component_ix i) (Region.load_relaxed other i);
    merge_from t other n (i + 1)
  end

let merge t other = merge_from t other t.n 0

let rec compare_from t other n i le ge =
  if i = n then
    match le, ge with
    | 1, 1 -> Equal
    | 1, 0 -> Before
    | 0, 1 -> After
    | _ -> Concurrent
  else
    let a = get t i in
    let b = Region.load_relaxed other i in
    let le = if a > b then 0 else le in
    let ge = if a < b then 0 else ge in
    compare_from t other n (i + 1) le ge

let compare t other = compare_from t other t.n 0 1 1

let pack t dst =
  let n = t.n in
  if Region.dim_words dst < n then false
  else begin
    let rec loop i =
      if i = n then ()
      else begin
        Region.store_relaxed dst i (get t i);
        loop (i + 1)
      end
    in
    loop 0;
    true
  end
