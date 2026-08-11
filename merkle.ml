(* Merkle-style hash tree over N (power of two) leaves of pooled state,
   as a 1-indexed implicit binary heap in a region slice: node i has
   children 2i and 2i+1; leaves occupy N..2N-1; slice size 2N words.

   Updating leaf j rehashes exactly the root path — O(log N), the same
   path an incremental-compute delta already touched. Comparing roots
   across Qnet nodes is one word; [proof]/[verify] let a node check a
   single leaf against a peer's root without shipping state.

   Hash = splitmix64-based mixer: fast, fine for CORRUPTION/DIVERGENCE
   detection between trusting nodes; NOT collision-resistant against an
   adversary — swap in a real hash (BLAKE3) behind the same interface
   for integrity against attackers. *)

type t = { s : Region.words; leaves : int }

let words_needed ~leaves = 2 * leaves

let mix x =
  let open Int64 in
  let z = add x 0x9E3779B97F4A7C15L in
  let z = mul (logxor z (shift_right_logical z 30)) 0xBF58476D1CE4E5B9L in
  let z = mul (logxor z (shift_right_logical z 27)) 0x94D049BB133111EBL in
  logxor z (shift_right_logical z 31)

let mix2 a b = mix (Int64.logxor (mix a) (Int64.mul b 0xD6E8FEB86659FD93L))

let init s ~leaves =
  for i = 0 to (2 * leaves) - 1 do s.{i} <- 0L done;
  let t = { s; leaves } in
  (* build interior once over the zeroed leaves *)
  for i = leaves - 1 downto 1 do
    s.{i} <- mix2 s.{2 * i} s.{(2 * i) + 1}
  done;
  t

let update t j value =
  let i = ref (t.leaves + j) in
  t.s.{!i} <- mix value;
  while !i > 1 do
    i := !i / 2;
    t.s.{!i} <- mix2 t.s.{2 * !i} t.s.{(2 * !i) + 1}
  done

let root t = t.s.{1}

(* sibling hashes bottom-up: enough for a peer to recompute the root *)
let proof t j =
  let rec up i acc =
    if i <= 1 then List.rev acc
    else up (i / 2) ((i land 1, t.s.{i lxor 1}) :: acc)
  in
  up (t.leaves + j) []

let verify ~leaf_value ~proof ~expected_root =
  let h =
    List.fold_left
      (fun h (i_am_right, sib) ->
        if i_am_right = 1 then mix2 sib h else mix2 h sib)
      (mix leaf_value) proof
  in
  h = expected_root
