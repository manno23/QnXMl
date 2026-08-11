(* Producer half: creates the named region, initializes the ring, publishes
   the magic word, then streams [n] messages and a checksummed sentinel.

   Control plane (SPEC B.3, roadmap 3): on QNX the producer owns a channel
   (the delta/ack server), publishes its pid+chid in the region header, waits
   for the consumer to register its own channel, connects to it, and signals
   "ring became nonempty" with MsgSendPulse instead of polling. The consumer
   blocks in MsgReceive for free. The ring stays the bulk data path; pulses
   are only the wakeup. After the sentinel, the producer blocks on its own
   channel for the consumer's status message (rcvid > 0 → must reply with a
   1-word ack; rcvid == 0 pulse → never reply; rcvid < 0 → error).

   Host build: channel_create raises Failure, so we fall back to the legacy
   polling loop — the demo still works under `make demo`. *)

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
  Region.sched_fifo Layout.producer_prio;
  Region.set_runmask Layout.producer_cpu;
  Printf.printf "producer: region %s ready (%d words, mlock=%b), sending %d\n%!"
    Layout.shm_name Layout.total_words r.Region.locked n;

  (* Staging lives in a private region, not the shared one: the consumer's
     out-buffer would otherwise race with these writes. *)
  let msg = Region.slice (Region.create ~words:Layout.width ()) Layout.width in
  let checksum = ref 0L in

  (* [notify] is how the producer tells the consumer there is data to drain:
     QNX = pulse on the consumer's control channel (never blocks);
     host = legacy poll sleep. *)
  let notify, ack =
    match Region.channel_create () with
    | chid ->
        (* publish pid/chid BEFORE the magic so an attach after magic sees
           the full control-plane contract (release order: data, then flag) *)
        Region.store_rel hdr 2 (Int64.of_int chid);
        Region.store_rel hdr 1 (Int64.of_int (Unix.getpid ()));
        Region.store_rel hdr 0 Layout.magic;
        Printf.printf "producer: channel %d (pid %d), pulse control plane\n%!"
          chid (Unix.getpid ());
        (* startup handshake only: wait for the consumer to register *)
        while Region.load_acq hdr 3 = 0L do Unix.sleepf 0.001 done;
        let coid =
          Region.connect_attach (Int64.to_int (Region.load_acq hdr 3))
            (Int64.to_int (Region.load_acq hdr 4))
        in
        Printf.printf "producer: connected to consumer channel (coid %d)\n%!" coid;
        (fun () -> Region.msg_send_pulse coid Layout.pulse_data_ready 0L), Some chid
    | exception Failure _ ->
        (* host build: no pulses, no handshake — legacy polling fallback *)
        Region.store_rel hdr 0 Layout.magic;
        print_endline "producer: host build — polling fallback (no pulses)";
        (fun () -> Unix.sleepf 1e-4), None
  in

  (* Throughput is measured with CLOCK_MONOTONIC (SPEC A.9 / roadmap 4):
     Unix.gettimeofday is CLOCK_REALTIME and can jump. *)
  let t0 = Region.monotonic () in
  for seq = 1 to n do
    msg.{0} <- Int64.of_int seq;
    msg.{1} <- Int64.mul (Int64.of_int seq) 3L;
    checksum := Int64.add !checksum msg.{1};
    while not (Ring.push ring msg) do notify () done
  done;
  msg.{0} <- Layout.sentinel;
  msg.{1} <- !checksum;
  while not (Ring.push ring msg) do notify () done;
  (* Final wake: the ring may be below capacity after the consumer's last
     drain, so no "full" pulse would ever fire — the consumer must still be
     told the stream ended. *)
  notify ();
  let dt = Region.monotonic () -. t0 in

  (* Delta/ack handshake (SPEC B.3 step 5, rcvid contract A.7): block on our
     own channel for the consumer's status message, reply with a 1-word ack.
     A pulse here is a client disconnect (_NTO_CHF_DISCONNECT) — never reply. *)
  (match ack with
   | Some chid ->
       let recv =
         Region.slice (Region.create ~words:Layout.ctl_words ()) Layout.ctl_words
       in
       let handshake () =
         let rcvid, nbytes = Region.msg_receive chid recv 0 Layout.ctl_words in
         if Region.is_pulse rcvid then begin
           (* rcvid == 0: pulse (consumer died / detached). Never reply. *)
           Printf.printf "producer: consumer disconnected (pulse code %d)\n%!"
             (Layout.pulse_code recv);
           exit 1
         end else if rcvid > 0 then begin
           (* rcvid > 0: real message. Validate the received length before
              trusting it (skill's validate-every-message rule). *)
           if nbytes <> 2 * 8 then
             Printf.eprintf "producer: status msg %d bytes, expected 16\n%!"
               nbytes;
           Printf.printf "producer: consumer status (%d bytes), acking\n%!"
             nbytes;
           Region.msg_replyv rcvid 0 recv 0 1
         end else begin
           (* rcvid < 0: error (-errno). Diagnose, do not reply. *)
           Printf.printf "producer: receive error rcvid=%d\n%!" rcvid;
           exit 1
         end
       in
       handshake ()
   | None -> ());

  Printf.printf "producer: %d msgs in %.3fs (%.0f msg/s), checksum %Ld\n%!"
    n dt (float_of_int n /. dt) !checksum
