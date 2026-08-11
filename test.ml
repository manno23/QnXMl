let check name b =
  Printf.printf "  %-46s %s\n" name (if b then "ok" else "FAIL");
  if not b then exit 1

let () =
  (* ---- one slab, sized up front, carved at init ------------------- *)
  let region = Region.create ~words:(1 lsl 16) () in
  Printf.printf "region: %d words at %nx, mlock=%b\n"
    (Bigarray.Array1.dim region.Region.mem)
    (Region.base_addr region.Region.mem)
    region.Region.locked;

  (* ---- ring ------------------------------------------------------- *)
  print_endline "ring:";
  let width = 4 and slots = 8 in
  let rs = Region.slice region (Ring.words_needed ~slots ~width) in
  let ring = Ring.init rs ~slots ~width in
  let msg = Region.slice region width and out = Region.slice region width in
  let fill v = for i = 0 to width - 1 do msg.{i} <- Int64.of_int (v + i) done in
  (* fill, drain, refill across the wrap boundary *)
  for v = 0 to slots - 1 do fill (100 * v); assert (Ring.push ring msg) done;
  fill 999;
  check "rejects push when full" (not (Ring.push ring msg));
  for _ = 1 to 3 do assert (Ring.pop ring out) done;
  for v = 0 to 2 do fill (7000 + v); assert (Ring.push ring msg) done;
  check "occupancy tracks through wraparound" (Ring.occupancy ring = slots);
  let ok = ref true in
  for v = 3 to slots - 1 do
    assert (Ring.pop ring out);
    ok := !ok && out.{0} = Int64.of_int (100 * v)
  done;
  for v = 0 to 2 do
    assert (Ring.pop ring out);
    ok := !ok && out.{0} = Int64.of_int (7000 + v)
  done;
  check "FIFO order preserved across wrap" !ok;
  check "rejects pop when empty" (not (Ring.pop ring out));

  (* ---- persistent map with bounded versions ----------------------- *)
  print_endline "pmap:";
  let cap = 4096 in
  let asl = Region.slice region (Arena.words_needed ~capacity:cap ~node_words:Pmap.node_words) in
  let arena = Arena.create asl ~capacity:cap ~node_words:Pmap.node_words in
  let m = Pmap.create arena ~retention:3 in
  let v1 = Pmap.set m 10L 100L in
  let v2 = Pmap.set m 20L 200L in
  let v3 = Pmap.set m 10L 111L in          (* overwrite in a NEW version *)
  check "newest sees overwrite" (Pmap.find m 10L = Some 111L);
  check "old version still sees original"
    (Pmap.find ~version:v1 m 10L = Some 100L);
  check "old version doesn't see the future"
    (Pmap.find ~version:v1 m 20L = None);
  ignore v2; ignore v3;
  (* churn: many versions; retention=3 must bound arena occupancy *)
  let hw = ref 0 in
  for i = 0 to 999 do
    ignore (Pmap.set m (Int64.of_int (i mod 50)) (Int64.of_int i));
    hw := max !hw (Pmap.nodes_in_use m)
  done;
  Printf.printf "  high-water nodes after 1000 versions: %d / %d\n" !hw cap;
  check "retirement bounds the pool" (!hw < cap);
  check "window holds exactly retention versions"
    (List.length (Pmap.live_versions m) = 3);
  check "map correct after churn" (Pmap.find m 49L = Some 999L);

  (* ---- version vectors -------------------------------------------- *)
  print_endline "vclock:";
  let peers = 4 in
  let c0 = Vclock.init (Region.slice region peers) ~peers ~me:0 in
  let incoming = Region.slice region peers in
  Vclock.tick c0; Vclock.tick c0;                (* we are at [2;0;0;0] *)
  for i = 0 to peers - 1 do incoming.{i} <- 0L done;
  incoming.{0} <- 2L; incoming.{1} <- 5L;        (* peer 1 got ahead    *)
  check "detects we're behind (apply delta)"
    (Vclock.compare c0 incoming = Vclock.Before);
  Vclock.merge c0 incoming;
  check "merge is componentwise max" (Vclock.get c0 1 = 5L && Vclock.get c0 0 = 2L);
  incoming.{1} <- 3L;
  check "detects stale delta (drop)" (Vclock.compare c0 incoming = Vclock.After);
  Vclock.tick c0;
  incoming.{1} <- 9L;                            (* each ahead somewhere *)
  check "detects concurrency" (Vclock.compare c0 incoming = Vclock.Concurrent);

  (* ---- merkle tree ------------------------------------------------ *)
  print_endline "merkle:";
  let leaves = 256 in
  let mk_a = Merkle.init (Region.slice region (Merkle.words_needed ~leaves)) ~leaves in
  let mk_b = Merkle.init (Region.slice region (Merkle.words_needed ~leaves)) ~leaves in
  check "identical empty state -> identical roots" (Merkle.root mk_a = Merkle.root mk_b);
  Merkle.update mk_a 17 424242L;
  check "divergence changes the root" (Merkle.root mk_a <> Merkle.root mk_b);
  Merkle.update mk_b 17 424242L;
  check "replaying the delta reconverges" (Merkle.root mk_a = Merkle.root mk_b);
  let p = Merkle.proof mk_a 17 in
  check "proof verifies true leaf against root"
    (Merkle.verify ~leaf_value:424242L ~proof:p ~expected_root:(Merkle.root mk_a));
  check "proof rejects tampered leaf"
    (not (Merkle.verify ~leaf_value:424243L ~proof:p ~expected_root:(Merkle.root mk_a)));

  Printf.printf "region words consumed: %d / %d\n"
    region.Region.cursor (Bigarray.Array1.dim region.Region.mem);
  print_endline "all tests passed"
