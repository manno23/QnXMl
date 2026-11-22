(** Consumer: attach the producer's region, wait until it is published,
    drain the ring. A dead pid/chid (the stale-session crash in
    docs/shell-capture.txt) is a negative errno from [connect_attach];
    the consumer unmaps and retries until the handshake deadline instead
    of dying on [Failure "ConnectAttach"]. *)

let deadline = Region.monotonic () +. Layout.handshake_timeout

let wait_ready () =
  match
    Retry.until
      ~now:Region.monotonic
      ~deadline
      ~wait:(fun () -> Unix.sleepf 0.02)
      ~f:(fun () ->
        match Region.attach ~name:Layout.shm_name ~words:Layout.total_words () with
        | Error (Region.Not_found | Region.Uninitialized | Region.Bad_magic) ->
            Retry.Again
        | Error e -> Retry.Stop e
        | Ok r ->
            (* A ready flag left by a dead producer is a stale session.
               Drop it and wait for a live creator (or for reclaim). *)
            if Region.is_ready r && Region.creator_alive r then Retry.Done r
            else begin
              Region.unmap r;
              Retry.Again
            end)
  with
  | Ok r -> r
  | Error `deadline ->
      Layout.die "consumer: handshake deadline (no ready region)"
  | Error (`stop e) ->
      Layout.die ("consumer: attach failed: " ^ Region.error_to_string e)

let () =
  let rec session () =
    if Region.monotonic () >= deadline then
      Layout.die "consumer: handshake deadline";
    let r = wait_ready () in
    let hdr = Layout.must_slice r Layout.header_words in
    let ring =
      match
        Ring.attach
          (Layout.must_slice r
             (Ring.words_needed ~slots:Layout.slots ~width:Layout.width))
      with
      | Ok ring -> ring
      | Error _ -> Layout.die "consumer: ring attach rejected the slice"
    in
    Region.sched_fifo Layout.consumer_prio;
    Region.set_runmask Layout.consumer_cpu;
    Printf.printf "consumer: attached to %s gen %d (mlock=%b)\n%!"
      Layout.shm_name (Region.generation r) (Region.locked r);

    let out = Layout.private_slice Layout.width in
    let expected = ref 1 and checksum = ref 0 and running = ref true in
    let in_order = ref true in

    let handle () =
      let seq = Region.load_relaxed out 0 in
      let payload = Region.load_relaxed out 1 in
      if seq = Layout.sentinel then begin
        running := false;
        if !checksum <> payload then begin
          Printf.printf "consumer: CHECKSUM MISMATCH got %d want %d\n%!"
            !checksum payload;
          exit 1
        end
      end else begin
        if seq <> !expected then in_order := false;
        checksum := !checksum + payload;
        expected := !expected + 1
      end
    in
    let drain () =
      while !running && Ring.pop ring out do handle () done
    in

    let finish () =
      if not !in_order then begin
        print_endline "consumer: OUT-OF-ORDER delivery";
        exit 1
      end;
      Printf.printf "consumer: %d msgs, FIFO order ok, checksum ok\n%!"
        (!expected - 1);
      Region.unlink Layout.shm_name
    in

    if not (Region.have_qnx_ipc ()) then begin
      while !running do
        if Ring.pop ring out then handle () else Unix.sleepf 1e-4
      done;
      finish ()
    end else
      match Region.channel_create () with
      | Error (`os e) ->
          Layout.die (Printf.sprintf "consumer: ChannelCreate failed (errno %d)" e)
      | Error `unavailable ->
          Layout.die "consumer: have_qnx_ipc disagreed with channel_create"
      | Ok chid ->
          Region.store_relaxed hdr Layout.consumer_chid chid;
          Region.store_int hdr Layout.consumer_pid (Unix.getpid ());
          let coid =
            Region.connect_attach
              (Region.load_int hdr Layout.producer_pid)
              (Region.load_int hdr Layout.producer_chid)
          in
          if coid < 0 then begin
            Printf.eprintf
              "consumer: ConnectAttach errno %d (stale session gen %d), retrying\n%!"
              (-coid) (Region.generation r);
            Region.unmap r;
            Unix.sleepf 0.05;
            session ()
          end else begin
            Printf.printf
              "consumer: control channel %d (pid %d), connected (coid %d)\n%!"
              chid (Unix.getpid ()) coid;
            let recv = Layout.private_slice Layout.ctl_words in
            (* Publish asleep BEFORE rechecking the ring, then block only if
               it is still empty. The producer arms after its push, so it
               cannot miss the transition where we drain the last item and
               sleep. *)
            let rec park () =
              if not !running then ()
              else begin
                Region.store_int hdr Layout.consumer_asleep 1;
                if Ring.occupancy ring > 0 then begin
                  Region.store_relaxed hdr Layout.consumer_asleep 0;
                  drain ();
                  park ()
                end else begin
                  let rcvid, nbytes =
                    Region.msg_receive chid recv 0 Layout.ctl_words
                  in
                  Region.store_relaxed hdr Layout.consumer_asleep 0;
                  if Region.is_pulse rcvid then begin
                    let code = Layout.pulse_code recv in
                    if code = Layout.pulse_disconnect then begin
                      Printf.printf "consumer: producer disconnected (pulse %d)\n%!"
                        code;
                      exit 1
                    end;
                    if code <> Layout.pulse_data_ready then
                      Printf.eprintf "consumer: unexpected pulse code %d\n%!" code;
                    drain ();
                    park ()
                  end else if rcvid > 0 then begin
                    if nbytes > Layout.ctl_words * 8 then
                      Printf.eprintf "consumer: oversized message %d bytes\n%!"
                        nbytes;
                    ignore (Region.msg_reply rcvid 0);
                    drain ();
                    park ()
                  end else begin
                    Printf.printf "consumer: receive error %d\n%!" rcvid;
                    exit 1
                  end
                end
              end
            in
            park ();
            let status = Layout.private_slice Layout.ctl_words in
            Region.store_relaxed status 0 (!expected - 1);
            Region.store_relaxed status 1 !checksum;
            let reply = Layout.private_slice 1 in
            Region.store_relaxed reply 0 0;
            let st = Region.msg_send coid status 0 2 reply in
            if st < 0 then
              Layout.die (Printf.sprintf "consumer: MsgSend errno %d" (-st));
            Printf.printf
              "consumer: status sent, reply status %d, ack word %d\n%!"
              st (Region.load_relaxed reply 0);
            finish ()
          end
  in
  session ()
