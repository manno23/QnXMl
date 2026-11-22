let check name b =
  Printf.printf "  %-46s %s\n%!" name (if b then "ok" else "FAIL");
  if not b then exit 1

let force_region = function
  | Ok v -> v
  | Error e ->
      Printf.eprintf "region: %s\n%!" (Region.error_to_string e);
      exit 1

let force msg = function
  | Ok v -> v
  | Error _ ->
      Printf.eprintf "%s\n%!" msg;
      exit 1

let shm name = Printf.sprintf "/qnxml_%s_%d" name (Unix.getpid ())

let map_lines () =
  let ic = open_in "/proc/self/maps" in
  let n = ref 0 in
  (try
     while true do
       ignore (input_line ic);
       incr n
     done
   with End_of_file -> ());
  close_in ic;
  !n

let dead_pid () =
  flush_all ();
  match Unix.fork () with
  | 0 -> Unix._exit 0
  | pid ->
      let _, st = Unix.waitpid [] pid in
      check "reaped helper child" (st = Unix.WEXITED 0);
      pid

let fork_arena () =
  let name = shm "arena" in
  Region.unlink name;
  let cap = 8 and nw = 2 in
  let aw = Arena.words_needed ~capacity:cap ~node_words:nw in
  let total = Region.descr_words + aw in
  let r = force_region (Region.create ~name ~words:total ()) in
  let s = force_region (Region.slice r aw) in
  let a = force "arena create" (Arena.create s ~capacity:cap ~node_words:nw) in
  let i = Arena.alloc a in
  check "parent alloc is node 0" (i = 0);
  Arena.set_int a i 1 0xDEAD;
  flush_all ();
  match Unix.fork () with
  | 0 ->
      let rc =
        match Region.attach ~name ~words:total () with
        | Error _ -> 2
        | Ok r2 ->
            match Region.slice r2 aw with
            | Error _ -> 3
            | Ok s2 ->
                match Arena.attach s2 with
                | Error _ -> 4
                | Ok a2 ->
                    let j = Arena.alloc a2 in
                    Arena.set_int a2 j 1 0xBEEF;
                    if j > 0 && Arena.get_int a2 0 1 = 0xDEAD then 0 else 5
      in
      Unix._exit rc
  | pid ->
      let _, st = Unix.waitpid [] pid in
      check "child attach does not double-alloc" (st = Unix.WEXITED 0);
      check "parent node 0 still 0xDEAD" (Arena.get_int a 0 1 = 0xDEAD);
      check "in_use is shared" (Arena.in_use a = 2);
      Region.unlink name

let fork_pmap () =
  let name = shm "pmap" in
  Region.unlink name;
  let cap = 64 and retention = 3 in
  let aw = Arena.words_needed ~capacity:cap ~node_words:Pmap.node_words in
  let pw = Pmap.words_needed ~retention ~capacity:cap in
  let total = Region.descr_words + aw + pw in
  let r = force_region (Region.create ~name ~words:total ()) in
  let arena =
    force "pmap arena"
      (Arena.create (force_region (Region.slice r aw))
         ~capacity:cap ~node_words:Pmap.node_words)
  in
  let m =
    force "pmap create"
      (Pmap.create arena (force_region (Region.slice r pw)) ~retention)
  in
  let id = Pmap.set m 10L 100L in
  check "pmap set id" (id > 0 && Pmap.find_eq m 10L 100L);
  flush_all ();
  match Unix.fork () with
  | 0 ->
      let rc =
        match Region.attach ~name ~words:total () with
        | Error _ -> 2
        | Ok r2 ->
            match Region.slice r2 aw with
            | Error _ -> 3
            | Ok asl ->
                match Arena.attach asl with
                | Error _ -> 4
                | Ok a2 ->
                    match Region.slice r2 pw with
                    | Error _ -> 5
                    | Ok meta ->
                        match Pmap.attach a2 meta with
                        | Error _ -> 6
                        | Ok m2 ->
                            if not (Pmap.find_eq m2 10L 100L) then 7
                            else if Pmap.set m2 20L 200L <= 0 then 8
                            else if Pmap.find_eq m2 20L 200L then 0
                            else 9
      in
      Unix._exit rc
  | pid ->
      let _, st = Unix.waitpid [] pid in
      check "child sees and extends pmap" (st = Unix.WEXITED 0);
      check "parent still sees original binding" (Pmap.find_eq m 10L 100L);
      check "parent sees child's version" (Pmap.find_eq m 20L 200L);
      Region.unlink name

let overhead () =
  Gc.full_major ();
  let best = ref 1e308 in
  for _ = 1 to 8 do
    let w0 = Gc.minor_words () in
    let w1 = Gc.minor_words () in
    let d = w1 -. w0 in
    if d < !best then best := d
  done;
  !best

let budget oh name n f =
  f 1;
  Gc.full_major ();
  let c0 = (Gc.quick_stat ()).Gc.minor_collections in
  let w0 = Gc.minor_words () in
  f n;
  let w1 = Gc.minor_words () in
  let c1 = (Gc.quick_stat ()).Gc.minor_collections in
  let words = (w1 -. w0) -. oh in
  let gcs = c1 - c0 in
  Printf.printf "  %-24s %8.2f words  %d minor GCs\n%!" name words gcs;
  check (name ^ " allocates nothing") (words = 0. && gcs = 0)

let allocation_budget () =
  print_endline "allocation budget (steady state):";
  let oh = overhead () in
  Printf.printf "  measurement overhead %.2f words\n%!" oh;
  let n = 200_000 in
  let region = force_region (Region.create ~words:(1 lsl 20) ()) in
  let slice words = force_region (Region.slice region words) in

  let slots = 64 and width = 4 in
  let ring =
    force "ring"
      (Ring.init (slice (Ring.words_needed ~slots ~width)) ~slots ~width)
  in
  let msg = slice width and out = slice width in
  for i = 0 to width - 1 do Region.store_relaxed msg i i done;
  let ring_failed = ref false in
  budget oh "Ring.push+pop" n (fun n ->
      for _ = 1 to n do
        if not (Ring.push ring msg) then ring_failed := true;
        if not (Ring.pop ring out) then ring_failed := true
      done);
  check "ring budget ops succeeded" (not !ring_failed);

  let peers = 4 in
  let c0 =
    force "vclock"
      (Vclock.init (slice (Vclock.words_needed ~peers)) ~peers ~me:0)
  in
  let incoming = slice peers in
  for i = 0 to peers - 1 do Region.store_relaxed incoming i 1 done;
  budget oh "Vclock tick/cmp/merge" n (fun n ->
      for _ = 1 to n do
        Vclock.tick c0;
        ignore (Vclock.compare c0 incoming);
        Vclock.merge c0 incoming
      done);

  let leaves = 256 in
  let mk =
    force "merkle"
      (Merkle.init (slice (Merkle.words_needed ~leaves)) ~leaves)
  in
  let one = 1L in
  budget oh "Merkle.update" n (fun n ->
      for i = 1 to n do Merkle.update mk (i land 255) one done);

  let cap = 4096 in
  let arena =
    force "arena"
      (Arena.create
         (slice (Arena.words_needed ~capacity:cap ~node_words:2))
         ~capacity:cap ~node_words:2)
  in
  budget oh "Arena alloc/free" n (fun n ->
      for _ = 1 to n do
        let i = Arena.alloc arena in
        Arena.set_int arena i 0 1;
        ignore (Arena.get_int arena i 0);
        ignore (Arena.free arena i)
      done);

  let pret = 4 and pcap = 1024 in
  let pa =
    force "pmap arena"
      (Arena.create
         (slice (Arena.words_needed ~capacity:pcap ~node_words:Pmap.node_words))
         ~capacity:pcap ~node_words:Pmap.node_words)
  in
  let pm =
    force "pmap"
      (Pmap.create pa
         (slice (Pmap.words_needed ~retention:pret ~capacity:pcap))
         ~retention:pret)
  in
  let keys =
    Array.init 16 (fun i -> (Int64.of_int i, Int64.of_int (1000 + i)))
  in
  Array.iter (fun (k, v) -> ignore (Pmap.set pm k v)) keys;
  let set_failed = ref false in
  budget oh "Pmap.set" n (fun n ->
      for i = 1 to n do
        let k, v = keys.(i land 15) in
        if Pmap.set pm k v <= 0 then set_failed := true
      done);
  check "pmap budget sets succeeded" (not !set_failed);
  let k, v = keys.(3) in
  check "pmap warmed" (Pmap.find_eq pm k v);
  budget oh "Pmap.find" n (fun n ->
      for _ = 1 to n do ignore (Pmap.find_eq pm k v) done)

let () =
  print_endline "cross-process:";
  fork_arena ();
  fork_pmap ();

  print_endline "region:";
  let region = force_region (Region.create ~words:(1 lsl 16) ()) in
  Printf.printf "region: %d words at %nx, mlock=%b\n%!"
    (Region.dim region)
    (Region.base_addr (Region.backing region))
    (Region.locked region);
  check "descriptor not yet published" (not (Region.is_ready region));
  Region.publish region;
  check "publish is acquire-visible" (Region.is_ready region);

  let name = shm "map" in
  Region.unlink name;
  let alive = Unix.getpid () in
  let mapped = force_region (Region.create ~name ~epoch:alive ~words:32 ()) in
  let user = force_region (Region.slice mapped (32 - Region.descr_words)) in
  Region.store_relaxed user 0 0x1234;
  Region.publish mapped;
  check "second create does not resize"
    (Region.create ~name ~words:32 () = Error Region.Exists);
  check "different size is not a truncate"
    (Region.create ~name ~words:64 () = Error Region.Exists);
  let r2 = force_region (Region.attach ~name ~words:32 ()) in
  let user2 = force_region (Region.slice r2 (32 - Region.descr_words)) in
  check "payload survived second create" (Region.load_relaxed user2 0 = 0x1234);
  check "attach larger than object"
    (Region.attach ~name ~words:64 () = Error Region.Too_small);
  check "attach smaller than descriptor"
    (match Region.attach ~name ~words:16 () with
    | Error (Region.Size_mismatch | Region.Too_small) -> true
    | _ -> false);
  Region.store_relaxed (Region.backing mapped) 0 0;
  check "zero magic is uninitialized"
    (Region.attach ~name ~words:32 () = Error Region.Uninitialized);
  Region.store_int (Region.backing mapped) 0 0x111;
  check "foreign magic is rejected"
    (Region.attach ~name ~words:32 () = Error Region.Bad_magic);
  let before_maps = map_lines () in
  for _ = 1 to 40 do
    match Region.attach ~name ~words:32 () with
    | Error Region.Bad_magic -> ()
    | _ -> check "repeated bad attach" false
  done;
  check "failed attach releases the mapping" (map_lines () - before_maps < 5);
  Region.unlink name;
  Region.unlink (name ^ "_lk");
  let dead = dead_pid () in
  let stale = force_region (Region.create ~name ~epoch:dead ~words:32 ()) in
  Region.publish stale;
  check "dead creator is not alive" (not (Region.creator_alive stale));
  let recovered =
    force_region (Region.recover ~name ~epoch:alive ~words:32 ())
  in
  check "recover bumps generation"
    (Region.generation recovered > Region.generation stale);
  check "recovered region is a new init" (not (Region.is_ready recovered));
  Region.publish recovered;
  check "live creator is busy"
    (Region.recover ~name ~epoch:alive ~words:32 () = Error Region.Busy);
  Region.unlink name;
  Region.unlink (name ^ "_lk");
  check "missing name" (Region.attach ~name ~words:32 () = Error Region.Not_found);

  (* Two recovers of one dead session: the survivor's bytes must stay. *)
  let race = shm "race" in
  Region.unlink race;
  let dead2 = dead_pid () in
  let stale2 = force_region (Region.create ~name:race ~epoch:dead2 ~words:32 ()) in
  Region.publish stale2;
  Region.unmap stale2;
  let to_parent_r, to_parent_w = Unix.pipe () in
  let to_child_r, to_child_w = Unix.pipe () in
  flush_all ();
  (match Unix.fork () with
  | 0 ->
      Unix.close to_parent_r;
      Unix.close to_child_w;
      let epoch = Unix.getpid () in
      let rc =
        match Region.recover ~name:race ~epoch ~words:32 () with
        | Error _ -> 2
        | Ok reg ->
            match Region.slice reg (32 - Region.descr_words) with
            | Error _ -> 3
            | Ok s ->
                Region.store_relaxed s 0 0xA1;
                Region.publish reg;
                let b = Bytes.make 1 'x' in
                ignore (Unix.write to_parent_w b 0 1);
                ignore (Unix.read to_child_r b 0 1);
                0
      in
      Unix._exit rc
  | holder ->
      Unix.close to_parent_w;
      Unix.close to_child_r;
      let b = Bytes.make 1 'x' in
      ignore (Unix.read to_parent_r b 0 1);
      flush_all ();
      let challenger =
        match Unix.fork () with
        | 0 ->
            Unix.close to_parent_r;
            Unix.close to_child_w;
            let rc =
              match Region.recover ~name:race ~epoch:(Unix.getpid ()) ~words:32 () with
              | Error Region.Busy -> 0
              | Ok _ -> 4
              | Error _ -> 5
            in
            Unix._exit rc
        | pid -> pid
      in
      let _, st = Unix.waitpid [] challenger in
      check "second recover leaves the live creator" (st = Unix.WEXITED 0);
      let seen = force_region (Region.attach ~name:race ~words:32 ()) in
      let slice = force_region (Region.slice seen (32 - Region.descr_words)) in
      check "live creator's marker was not replaced"
        (Region.load_relaxed slice 0 = 0xA1);
      ignore (Unix.write to_child_w b 0 1);
      let _, st = Unix.waitpid [] holder in
      check "holding recoverer exits cleanly" (st = Unix.WEXITED 0);
      Region.unlink race;
      Region.unlink (race ^ "_lk"));

  print_endline "ipc capability:";
  check "this host is not QNX" (not (Region.have_qnx_ipc ()));
  check "channel_create is unavailable"
    (Region.channel_create () = Error `unavailable);
  let buf = force_region (Region.slice region 4) in
  let reply = force_region (Region.slice region 2) in
  check "pulse returns errno" (Region.msg_send_pulse 1 1 0 = -Region.enotsup);
  check "msg_send returns errno" (Region.msg_send 1 buf 0 1 reply = -Region.enotsup);
  let owed = ref true in
  let calls = ref 0 in
  let rc = Wake.send ~owed ~pulse:(fun () -> incr calls; -Region.eagain) in
  check "EAGAIN keeps the wakeup owed" (!owed && rc = -Region.eagain && !calls = 1);
  let rc = Wake.send ~owed ~pulse:(fun () -> incr calls; 0) in
  check "a landed pulse clears the debt" ((not !owed) && rc = 0);
  let rc = Wake.send ~owed ~pulse:(fun () -> incr calls; 0) in
  check "coalesce skips a second pulse" (!calls = 2 && rc = 0);
  let word = ref 0 in
  let pulses = ref 0 in
  let load () = !word in
  let cas old now =
    if !word = old then begin
      word := now;
      true
    end else false
  in
  word := 0;
  check "arm does not pulse a running consumer"
    (Wake.arm ~load ~cas ~pulse:(fun () -> incr pulses; 0) = Wake.Awake && !pulses = 0);
  word := 1;
  check "arm pulses a published sleeper once"
    (Wake.arm ~load ~cas ~pulse:(fun () -> incr pulses; 0) = Wake.Pulsed
     && !word = 0 && !pulses = 1);
  word := 1;
  pulses := 0;
  check "EAGAIN restores the sleeper flag"
    (match Wake.arm ~load ~cas ~pulse:(fun () -> incr pulses; -Region.eagain) with
     | Wake.Again rc -> rc = -Region.eagain && !word = 1 && !pulses = 1
     | _ -> false);
  check "restored sleeper can be pulsed"
    (Wake.arm ~load ~cas ~pulse:(fun () -> incr pulses; 0) = Wake.Pulsed && !word = 0);

  let now = ref 0 in
  let ntry = ref 0 in
  let step =
    Retry.until ~now:(fun () -> !now) ~deadline:3
      ~wait:(fun () -> incr now)
      ~f:(fun () ->
        incr ntry;
        if !ntry < 3 then Retry.Again else Retry.Done 7)
  in
  check "retry succeeds before the deadline" (step = Ok 7 && !now = 2);
  let now = ref 0 in
  let stopped =
    Retry.until ~now:(fun () -> !now) ~deadline:5
      ~wait:(fun () -> incr now)
      ~f:(fun () -> Retry.Again)
  in
  check "retry reports the deadline" (stopped = Error `deadline);

  let cell = force_region (Region.slice region 1) in
  check "cas-max stays monotone under pthreads"
    (Region.atomic_max_self_test cell 0 1000 100_000 = 0);

  print_endline "ring:";
  let width = 4 and slots = 8 in
  let rs = force_region (Region.slice region (Ring.words_needed ~slots ~width)) in
  check "attach rejects a zeroed ring"
    (match Ring.attach rs with
    | Error Ring.Bad_geometry -> true
    | _ -> false);
  let ring = force "ring init" (Ring.init rs ~slots ~width) in
  check "attach accepts an initialized ring"
    (match Ring.attach rs with
    | Ok _ -> true
    | Error _ -> false);
  let msg = force_region (Region.slice region width) in
  let out = force_region (Region.slice region width) in
  let fill v =
    for i = 0 to width - 1 do Region.store_relaxed msg i (v + i) done
  in
  for v = 0 to slots - 1 do
    fill (100 * v);
    check "push" (Ring.push ring msg)
  done;
  fill 999;
  check "rejects push when full" (not (Ring.push ring msg));
  for _ = 1 to 3 do check "pop" (Ring.pop ring out) done;
  for v = 0 to 2 do
    fill (7000 + v);
    check "push wrap" (Ring.push ring msg)
  done;
  check "occupancy tracks through wraparound" (Ring.occupancy ring = slots);
  let ok = ref true in
  for v = 3 to slots - 1 do
    ignore (Ring.pop ring out);
    ok := !ok && Region.load_relaxed out 0 = 100 * v
  done;
  for v = 0 to 2 do
    ignore (Ring.pop ring out);
    ok := !ok && Region.load_relaxed out 0 = 7000 + v
  done;
  check "FIFO order preserved across wrap" !ok;
  check "rejects pop when empty" (not (Ring.pop ring out));

  print_endline "arena:";
  let aslice =
    force_region (Region.slice region (Arena.words_needed ~capacity:2 ~node_words:2))
  in
  let tiny = force "tiny" (Arena.create aslice ~capacity:2 ~node_words:2) in
  let a0 = Arena.alloc tiny in
  let a1 = Arena.alloc tiny in
  check "alloc hands out distinct nodes" (a0 = 0 && a1 = 1);
  check "exhaustion is a result" (Arena.alloc_res tiny = Error `exhausted);
  check "free" (Arena.free tiny a0);
  check "double-free is rejected" (not (Arena.free tiny a0));
  check "free out of range" (not (Arena.free tiny 9));
  let a2 = Arena.alloc tiny in
  check "alloc reuses the freed node" (a2 = a0);
  let viewed = force "arena attach" (Arena.attach aslice) in
  check "attach sees the same in_use" (Arena.in_use viewed = Arena.in_use tiny);
  Arena.set_int tiny a1 1 0xABC;
  check "attach reads the same node" (Arena.get_int viewed a1 1 = 0xABC);

  print_endline "pmap:";
  let cap = 4096 in
  let pa =
    force "pa"
      (Arena.create
         (force_region
            (Region.slice region
               (Arena.words_needed ~capacity:cap ~node_words:Pmap.node_words)))
         ~capacity:cap ~node_words:Pmap.node_words)
  in
  let m =
    force "pm"
      (Pmap.create pa
         (force_region
            (Region.slice region (Pmap.words_needed ~retention:3 ~capacity:cap)))
         ~retention:3)
  in
  let v1 = Pmap.set m 10L 100L in
  let _v2 = Pmap.set m 20L 200L in
  let _v3 = Pmap.set m 10L 111L in
  check "newest sees overwrite" (Pmap.find_eq m 10L 111L);
  check "old version still sees original" (Pmap.find_eq ~version:v1 m 10L 100L);
  check "old version doesn't see the future" (not (Pmap.mem ~version:v1 m 20L));
  let hw = ref 0 in
  for i = 0 to 999 do
    ignore (Pmap.set m (Int64.of_int (i mod 50)) (Int64.of_int i));
    hw := max !hw (Pmap.nodes_in_use m)
  done;
  Printf.printf "  high-water nodes after 1000 versions: %d / %d\n%!" !hw cap;
  check "retirement bounds the pool" (!hw < cap && !hw > 0);
  check "window holds exactly retention versions" (Pmap.live_count m = 3);
  check "map correct after churn" (Pmap.find_eq m 49L 999L);
  check "early version retired" (not (Pmap.has_version m v1));
  check "failure sentinel is not a version" (not (Pmap.has_version m (-1)));
  let tiny_cap = 2 in
  let tiny_arena =
    force "tiny pmap arena"
      (Arena.create
         (force_region
            (Region.slice region
               (Arena.words_needed ~capacity:tiny_cap ~node_words:Pmap.node_words)))
         ~capacity:tiny_cap ~node_words:Pmap.node_words)
  in
  let tiny_map =
    force "tiny pmap"
      (Pmap.create tiny_arena
         (force_region
            (Region.slice region
               (Pmap.words_needed ~retention:2 ~capacity:tiny_cap)))
         ~retention:2)
  in
  check "tiny map accepts the first key" (Pmap.set tiny_map 10L 100L > 0);
  check "failed insert rolls the pool back"
    (Pmap.set tiny_map 20L 200L = -1 && Pmap.nodes_in_use tiny_map = 1);
  check "rolled-back map still has the first key" (Pmap.find_eq tiny_map 10L 100L);
  check "rolled-back map has no partial key" (not (Pmap.mem tiny_map 20L));
  check "overwrite still fits after the rollback"
    (Pmap.set tiny_map 10L 111L > 0 && Pmap.find_eq tiny_map 10L 111L);

  print_endline "vclock:";
  let peers = 4 in
  let c0 =
    force "vc"
      (Vclock.init
         (force_region (Region.slice region (Vclock.words_needed ~peers)))
         ~peers ~me:0)
  in
  let incoming = force_region (Region.slice region peers) in
  Vclock.tick c0;
  Vclock.tick c0;
  for i = 0 to peers - 1 do Region.store_relaxed incoming i 0 done;
  Region.store_relaxed incoming 0 2;
  Region.store_relaxed incoming 1 5;
  check "detects we're behind (apply delta)"
    (Vclock.compare c0 incoming = Vclock.Before);
  Vclock.merge c0 incoming;
  check "merge is componentwise max" (Vclock.get c0 1 = 5 && Vclock.get c0 0 = 2);
  Region.store_relaxed incoming 1 3;
  check "detects stale delta (drop)" (Vclock.compare c0 incoming = Vclock.After);
  Vclock.merge c0 incoming;
  check "stale merge does not move backwards" (Vclock.get c0 1 = 5);
  Vclock.tick c0;
  check "tick after merge counts the new event" (Vclock.get c0 0 = 3);
  Region.store_relaxed incoming 1 9;
  check "detects concurrency" (Vclock.compare c0 incoming = Vclock.Concurrent);
  let packed = force_region (Region.slice region peers) in
  check "pack writes the dense wire vector" (Vclock.pack c0 packed);
  check "packed component matches" (Region.load_relaxed packed 1 = Vclock.get c0 1);
  check "attach rejects a zero peer count"
    (match
       Vclock.attach (force_region (Region.slice region (Vclock.words_needed ~peers)))
         ~me:0
     with
    | Error Vclock.Bad_peers -> true
    | _ -> false);

  print_endline "merkle:";
  let leaves = 256 in
  let mk_a =
    force "mka"
      (Merkle.init
         (force_region (Region.slice region (Merkle.words_needed ~leaves)))
         ~leaves)
  in
  let mk_b =
    force "mkb"
      (Merkle.init
         (force_region (Region.slice region (Merkle.words_needed ~leaves)))
         ~leaves)
  in
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
  check "proof rejects an out-of-range leaf" (Merkle.proof mk_a leaves = []);
  check "merkle rejects an overflowing leaf count"
    (match Merkle.init (force_region (Region.slice region 4)) ~leaves:max_int with
     | Error Merkle.Bad_leaves -> true
     | _ -> false);
  check "arena rejects an overflowing node size"
    (match
       Arena.create (force_region (Region.slice region 8)) ~capacity:2
         ~node_words:max_int
     with
     | Error Arena.Bad_size -> true
     | _ -> false);
  check "pmap rejects an overflowing retention"
    (match
       Pmap.create pa (force_region (Region.slice region 32)) ~retention:max_int
     with
     | Error Pmap.Bad_size -> true
     | _ -> false);
  check "vclock attach rejects an empty slice"
    (match Vclock.attach (force_region (Region.slice region 0)) ~me:0 with
     | Error Vclock.Bad_peers -> true
     | _ -> false);
  let epoch_name = shm "epoch" in
  Region.unlink epoch_name;
  let epoch_region =
    force_region (Region.create ~name:epoch_name ~words:32 ())
  in
  check "default epoch is this process" (Region.epoch epoch_region = Unix.getpid ());
  Region.unlink epoch_name;
  Region.unlink (epoch_name ^ "_lk");

  allocation_budget ();

  Printf.printf "region words consumed: %d / %d\n%!"
    (Region.cursor region) (Region.dim region);
  print_endline "all tests passed"
