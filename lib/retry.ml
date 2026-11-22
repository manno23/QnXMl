type ('a, 'e) step =
  | Done of 'a
  | Again
  | Stop of 'e

let until ~now ~deadline ~wait ~f =
  let rec go () =
    match f () with
    | Done v -> Ok v
    | Stop e -> Error (`stop e)
    | Again ->
        if now () >= deadline then Error `deadline
        else begin
          wait ();
          go ()
        end
  in
  go ()
