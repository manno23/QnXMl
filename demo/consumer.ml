(* Consumer half: attaches to the producer's named region (retrying until it
   exists), waits for the magic word, then drains the ring verifying FIFO
   order and the sentinel checksum. Exit 0 = everything matched.

   Control plane (SPEC B.3, roadmap 3): on QNX the consumer owns its own
   channel, publishes its pid+chid in the region header, connects to the
   producer's channel, and BLOCKS in MsgReceive instead of polling. The
   producer's "data ready" pulse (rcvid == 0) is handled and never replied
   to; the drain runs only when woken. After the sentinel it sends its status
   as a real message (rcvid > 0 on the producer's side, which must reply)
   and prints the ack.

   rcvid contract enforced here (skill architecture.md §2):
     rcvid > 0  must reply
     rcvid == 0 pulse, never reply
     rcvid < 0  error, diagnose, do not reply

   Host build: channel_create raises Failure, so we keep the legacy polling
   loop — `make demo` works unchanged. *)

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
  Region.sched_fifo Layout.consumer_prio;
  Region.set_runmask Layout.consumer_cpu;
  Printf.printf "consumer: attached to %s (mlock=%b)\n%!"
    Layout.shm_name r.Region.locked;

  let out = Region.slice (Region.create ~words:Layout.width ()) Layout.width in
  let expected = ref 1L and checksum = ref 0L and running = ref true in
  let in_order = ref true in

  let handle () =
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
  in

  let drain () =
    while !running && Ring.pop ring out do handle () done
  in

  (match Region.channel_create () with
   | chid ->
       (* Publish our own channel (data word first, then the release flag
          word the producer waits on) so the producer can connect back. *)
       Region.store_rel hdr 4 (Int64.of_int chid);
       Region.store_rel hdr 3 (Int64.of_int (Unix.getpid ()));
       let coid =
         Region.connect_attach (Int64.to_int (Region.load_acq hdr 1))
           (Int64.to_int (Region.load_acq hdr 2))
       in
       Printf.printf "consumer: control channel %d (pid %d), connected (coid %d)\n%!"
         chid (Unix.getpid ()) coid;
       let recv =
         Region.slice (Region.create ~words:Layout.ctl_words ()) Layout.ctl_words
       in
       let rec loop () =
         (* drain whatever is there, then park in MsgReceive *)
         drain ();
         if !running then begin
           let rcvid, nbytes = Region.msg_receive chid recv 0 Layout.ctl_words in
           if Region.is_pulse rcvid then begin
             (* rcvid == 0: pulse — handle, NEVER reply. *)
             let code = Layout.pulse_code recv in
             if code = Layout.pulse_disconnect then begin
               Printf.printf "consumer: producer disconnected (pulse %d)\n%!"
                 code;
               exit 1
             end;
             if code <> Layout.pulse_data_ready then
               Printf.eprintf "consumer: unexpected pulse code %d\n%!" code;
             loop ()
           end else if rcvid > 0 then begin
             (* rcvid > 0: real message — validate length, MUST reply. *)
             if nbytes > Layout.ctl_words * 8 then
               Printf.eprintf "consumer: oversized message %d bytes\n%!"
                 nbytes;
             Region.msg_reply rcvid 0;
             loop ()
           end else begin
             (* rcvid < 0: error — diagnose, do not reply. *)
             Printf.printf "consumer: receive error rcvid=%d\n%!" rcvid;
             exit 1
           end
         end
       in
       loop ();
       (* Delta/ack handshake (SPEC B.3 step 5): report status, expect the
          producer's 1-word ack. MsgSend blocks until the reply lands. *)
       let status =
         Region.slice (Region.create ~words:Layout.ctl_words ()) Layout.ctl_words
       in
       status.{0} <- Int64.sub !expected 1L;
       status.{1} <- !checksum;
       let rc = Region.msg_send coid status 0 2 in
       Printf.printf "consumer: status sent, ack received (%d reply bytes)\n%!"
         rc
   | exception Failure _ ->
       (* host build: no pulses — legacy polling loop *)
       while !running do
         if Ring.pop ring out then handle () else Unix.sleepf 1e-4
       done);

  if not !in_order then begin
    print_endline "consumer: OUT-OF-ORDER delivery"; exit 1
  end;
  Printf.printf "consumer: %Ld msgs, FIFO order ok, checksum ok\n%!"
    (Int64.sub !expected 1L);
  Region.unlink Layout.shm_name
