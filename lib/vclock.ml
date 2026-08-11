(* Version vector for a FIXED, known-in-advance peer set — one monotone
   int64 counter per peer, living in the region so a delta header can be
   MsgSent as a word-range with zero serialization.

   Use: bump own component on every locally produced delta; on receipt,
   [compare incoming local] decides accept / stale / concurrent, then
   [merge]. Monotonicity of each component is the invariant the module
   never lets you break: there is no [set], only [tick] and [merge].

   Layout (word indices within the slice):
     0      : n — peer count (read-only after init)
     1–7    : padding
     8(i+1) : counter of peer i, on its own 64-byte cache line

   Padding decision (SPEC A.5): the counters ARE written by different
   processes — peer i ticks only its own component i from a pinned core —
   so adjacent counters would false-share exactly like Ring's head/tail.
   A Cortex-A76 cache line is 64 bytes = 8 int64 words, so each counter
   lives at word 8*(i+1), its own line; read-only n shares line 0
   harmlessly.

   The wire format is UNCHANGED and dense: [compare]/[merge] take an
   incoming vector of n words in peer order, and the padding above exists
   only in the resident copy. A peer sending its own clock packs its
   counters into the outbound staging slice before MsgSendv. *)

type t = { s : Region.words; me : int; n : int }

type order = Equal | Before | After | Concurrent

let line_words = 8    (* one 64-byte cache line (Cortex-A76) *)
let n_ix = 0
let component_ix i = line_words * (i + 1)

let words_needed ~peers = line_words * (peers + 1)

let init s ~peers ~me =
  s.{n_ix} <- Int64.of_int peers;
  for i = 0 to peers - 1 do s.{component_ix i} <- 0L done;
  { s; me; n = peers }

let attach s ~me = { s; me; n = Int64.to_int s.{n_ix} }

let tick t = ignore (Region.fetch_add t.s (component_ix t.me) 1L)

let get t i = Region.load_acq t.s (component_ix i)

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
    if b > a then Region.store_rel t.s (component_ix i) b
  done
