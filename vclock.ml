(* Version vector for a FIXED, known-in-advance peer set — one monotone
   int64 counter per peer, living in the region so a delta header can be
   MsgSent as a word-range with zero serialization.

   Use: bump own component on every locally produced delta; on receipt,
   [compare incoming local] decides accept / stale / concurrent, then
   [merge]. Monotonicity of each component is the invariant the module
   never lets you break: there is no [set], only [tick] and [merge]. *)

type t = { s : Region.words; me : int; n : int }

type order = Equal | Before | After | Concurrent

let words_needed ~peers = peers

let init s ~peers ~me =
  for i = 0 to peers - 1 do s.{i} <- 0L done;
  { s; me; n = peers }

let attach s ~me = { s; me; n = Region.dim s }

let tick t = ignore (Region.fetch_add t.s t.me 1L)

let get t i = Region.load_acq t.s i

(* compare THIS clock against a raw incoming vector (n words) *)
let compare t (other : Region.words) =
  let le = ref true and ge = ref true in
  for i = 0 to t.n - 1 do
    let a = get t i and b = other.{i} in
    if a < b then ge := false;
    if a > b then le := false
  done;
  match !le, !ge with
  | true, true -> Equal
  | true, false -> Before        (* we're behind: apply the delta *)
  | false, true -> After         (* delta is stale: drop it       *)
  | false, false -> Concurrent   (* needs merge policy            *)

let merge t (other : Region.words) =
  for i = 0 to t.n - 1 do
    let a = get t i and b = other.{i} in
    if b > a then Region.store_rel t.s i b
  done
