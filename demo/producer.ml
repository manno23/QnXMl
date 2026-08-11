(* Producer half: creates the named region, initializes the ring, publishes
   the magic word, then streams [n] messages and a checksummed sentinel.
   Run before or after the consumer — the consumer retries attach. *)

let () =
  let n = try int_of_string Sys.argv.(1) with _ -> 100_000 in
  (* Fresh object each run: a stale region from a crashed run would carry an
     old magic and a mid-stream ring. *)
  Region.unlink Layout.shm_name;
  let r = Region.create ~name:Layout.shm_name ~words:Layout.total_words () in
  let hdr = Region.slice r Layout.header_words in
  let ring =
    Ring.init
      (Region.slice r (Ring.words_needed ~slots:Layout.slots ~width:Layout.width))
      ~slots:Layout.slots ~width:Layout.width
  in
  Region.store_rel hdr 0 Layout.magic;
  Printf.printf "producer: region %s ready (%d words, mlock=%b), sending %d\n%!"
    Layout.shm_name Layout.total_words r.Region.locked n;

  (* Staging lives in a private region, not the shared one: the consumer's
     out-buffer would otherwise race with these writes. *)
  let msg = Region.slice (Region.create ~words:Layout.width ()) Layout.width in
  let checksum = ref 0L in
  let t0 = Unix.gettimeofday () in
  for seq = 1 to n do
    msg.{0} <- Int64.of_int seq;
    msg.{1} <- Int64.mul (Int64.of_int seq) 3L;
    checksum := Int64.add !checksum msg.{1};
    while not (Ring.push ring msg) do Unix.sleepf 1e-4 done
  done;
  msg.{0} <- Layout.sentinel;
  msg.{1} <- !checksum;
  while not (Ring.push ring msg) do Unix.sleepf 1e-4 done;
  let dt = Unix.gettimeofday () -. t0 in
  Printf.printf "producer: %d msgs in %.3fs (%.0f msg/s), checksum %Ld\n%!"
    n dt (float_of_int n /. dt) !checksum
