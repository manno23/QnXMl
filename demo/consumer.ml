(* Consumer half: attaches to the producer's named region (retrying until it
   exists), waits for the magic word, then drains the ring verifying FIFO
   order and the sentinel checksum. Exit 0 = everything matched. *)

let rec attach () =
  try Region.attach ~name:Layout.shm_name ~words:Layout.total_words ()
  with Failure _ -> Unix.sleepf 0.05; attach ()

let () =
  let r = attach () in
  let hdr = Region.slice r Layout.header_words in
  let ring_slice =
    Region.slice r (Ring.words_needed ~slots:Layout.slots ~width:Layout.width)
  in
  while Region.load_acq hdr 0 <> Layout.magic do Unix.sleepf 0.01 done;
  let ring = Ring.attach ring_slice in
  Printf.printf "consumer: attached to %s (mlock=%b)\n%!"
    Layout.shm_name r.Region.locked;

  let out = Region.slice (Region.create ~words:Layout.width ()) Layout.width in
  let expected = ref 1L and checksum = ref 0L and running = ref true in
  let in_order = ref true in
  while !running do
    if Ring.pop ring out then begin
      if out.{0} = Layout.sentinel then begin
        running := false;
        if !checksum <> out.{1} then begin
          Printf.printf "consumer: CHECKSUM MISMATCH got %Ld want %Ld\n%!"
            !checksum out.{1};
          exit 1
        end
      end else begin
        if out.{0} <> !expected then in_order := false;
        checksum := Int64.add !checksum out.{1};
        expected := Int64.add !expected 1L
      end
    end
    else Unix.sleepf 1e-4
  done;
  if not !in_order then begin
    print_endline "consumer: OUT-OF-ORDER delivery"; exit 1
  end;
  Printf.printf "consumer: %Ld msgs, FIFO order ok, checksum ok\n%!"
    (Int64.sub !expected 1L);
  Region.unlink Layout.shm_name
