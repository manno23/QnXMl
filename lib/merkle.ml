type t = { s : Region.words; leaves : int }
type error = Bad_leaves

external init_c : Region.words -> int -> unit = "qr_merkle_init" [@@noalloc]
external update_c : Region.words -> int -> int -> int64 -> unit
  = "qr_merkle_update" [@@noalloc]
external root_c : Region.words -> int64 = "qr_merkle_root"
external mix : int64 -> int64 = "qr_mix64"
external mix2 : int64 -> int64 -> int64 = "qr_mix2"

let words_needed ~leaves =
  if leaves <= 0 || leaves > max_int / 2 then 0 else leaves * 2

let init s ~leaves =
  let need = words_needed ~leaves in
  if need = 0 || need > Region.dim_words s then Error Bad_leaves
  else begin
    init_c s leaves;
    Ok { s; leaves }
  end

let update t j value =
  if j >= 0 && j < t.leaves then update_c t.s t.leaves j value

let root t = root_c t.s

let proof t j =
  if j < 0 || j >= t.leaves then []
  else
    let _acquire = root t in
  let rec up i acc =
    if i <= 1 then List.rev acc
    else
      let sib = Region.load_int64 t.s (i lxor 1) in
      up (i / 2) ((i land 1, sib) :: acc)
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
