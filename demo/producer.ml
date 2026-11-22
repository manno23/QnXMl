(** Producer: create or reclaim the named region, publish the ring, stream
    [n] messages. On QNX the wakeup is one pulse per empty→nonempty
    transition; EAGAIN backs off and retries. On the host (no QNX IPC)
    the same ring is polled. Host versus QNX is [Region.have_qnx_ipc],
    not a caught [Failure]. *)

let claim () =
  let epoch = Unix.getpid () in
  let words = Layout.total_words in
  let name = Layout.shm_name in
  match Region.create ~name ~epoch ~words () with
  | Ok r -> r
  | Error Region.Exists ->
      begin match Region.recover ~name ~epoch ~words () with
      | Ok r ->
          Printf.printf "producer: reclaimed stale region (generation %d)\n%!"
            (Region.generation r);
          r
      | Error Region.Busy ->
          Layout.die "producer: another live producer holds the region"
      | Error e ->
          Layout.die ("producer: recover failed: " ^ Region.error_to_string e)
      end
  | Error e ->
      Layout.die ("producer: create failed: " ^ Region.error_to_string e)

let wait_consumer hdr =
  let deadline = Region.monotonic () +. Layout.handshake_timeout in
  match
    Retry.until
      ~now:Region.monotonic
      ~deadline
      ~wait:(fun () -> Unix.sleepf 0.001)
      ~f:(fun () ->
        if Region.load_int hdr Layout.consumer_pid <> 0 then Retry.Done ()
        else Retry.Again)
  with
  | Ok () -> ()
  | Error _ -> Layout.die "producer: handshake deadline waiting for consumer"

let connect_consumer hdr =
  let deadline = Region.monotonic () +. Layout.handshake_timeout in
  Retry.until
    ~now:Region.monotonic
    ~deadline
    ~wait:(fun () -> Unix.sleepf 0.01)
    ~f:(fun () ->
      let pid = Region.load_int hdr Layout.consumer_pid in
      let chid = Region.load_int hdr Layout.consumer_chid in
      if pid = 0 then Retry.Again
      else
        let coid = Region.connect_attach pid chid in
        if coid >= 0 then Retry.Done coid else Retry.Again)

let () =
  let n = try int_of_string Sys.argv.(1) with _ -> 100_000 in
  let r = claim () in
  let hdr = Layout.must_slice r Layout.header_words in
  let ring =
    match
      Ring.init
        (Layout.must_slice r (Ring.words_needed ~slots:Layout.slots ~width:Layout.width))
        ~slots:Layout.slots ~width:Layout.width
    with
    | Ok ring -> ring
    | Error _ -> Layout.die "producer: ring init failed"
  in
  Region.sched_fifo Layout.producer_prio;
  Region.set_runmask Layout.producer_cpu;
  Printf.printf "producer: region %s ready (%d words, mlock=%b), sending %d\n%!"
    Layout.shm_name Layout.total_words (Region.locked r) n;

  let msg = Layout.private_slice Layout.width in
  Region.store_relaxed msg 2 0;
  Region.store_relaxed msg 3 0;
  let checksum = ref 0 in

  let push_host () =
    while not (Ring.push ring msg) do Unix.sleepf 1e-4 done
  in

  let push_qnx, finish =
    match Region.channel_create () with
    | Error `unavailable ->
        Region.store_int hdr Layout.producer_pid (Unix.getpid ());
        Region.publish r;
        print_endline "producer: host build — polling fallback (no pulses)";
        (* Stay alive until the ring is empty. A stream that fits in the
           ring would otherwise exit before the consumer attaches, and the
           consumer would reject the now-dead creator. *)
        let wait_drain () =
          let deadline = Region.monotonic () +. Layout.handshake_timeout in
          let rec go () =
            if Ring.occupancy ring = 0 then ()
            else if Region.monotonic () >= deadline then
              Layout.die "producer: deadline waiting for the consumer to drain"
            else begin
              Unix.sleepf 0.001;
              go ()
            end
          in
          go ()
        in
        (push_host, wait_drain)
    | Error (`os e) ->
        Layout.die (Printf.sprintf "producer: ChannelCreate failed (errno %d)" e)
    | Ok chid ->
        Region.store_relaxed hdr Layout.producer_chid chid;
        Region.store_int hdr Layout.producer_pid (Unix.getpid ());
        Region.publish r;
        Printf.printf "producer: channel %d (pid %d), pulse control plane\n%!"
          chid (Unix.getpid ());
        wait_consumer hdr;
        let coid =
          match connect_consumer hdr with
          | Ok coid -> coid
          | Error _ ->
              Layout.die "producer: handshake deadline connecting to consumer"
        in
        Printf.printf "producer: connected to consumer channel (coid %d)\n%!" coid;
        let pulse () = Region.msg_send_pulse coid Layout.pulse_data_ready 0 in
        let wake () =
          Wake.arm
            ~load:(fun () -> Region.load_int hdr Layout.consumer_asleep)
            ~cas:(fun old now ->
              Region.cas_int hdr Layout.consumer_asleep old now)
            ~pulse
        in
        let rec kick () =
          match wake () with
          | Wake.Awake | Wake.Pulsed -> ()
          | Wake.Again rc when rc = -Region.eagain ->
              Unix.sleepf 1e-4;
              kick ()
          | Wake.Again rc ->
              Layout.die (Printf.sprintf "producer: MsgSendPulse errno %d" (-rc))
        in
        (* Push, then arm. The occupancy bit is not the wakeup: the consumer
           can drain and sleep between a nonempty observation and the push.
           [Wake.arm] runs after the push's release of tail. *)
        let push () =
          let rec go () =
            if Ring.push ring msg then kick ()
            else begin
              kick ();
              Unix.sleepf 1e-4;
              go ()
            end
          in
          go ()
        in
        let finish () =
          kick ();
          let recv = Layout.private_slice Layout.ctl_words in
          let rcvid, nbytes = Region.msg_receive chid recv 0 Layout.ctl_words in
          if Region.is_pulse rcvid then begin
            Printf.printf "producer: consumer disconnected (pulse code %d)\n%!"
              (Layout.pulse_code recv);
            exit 1
          end else if rcvid > 0 then begin
            if nbytes <> 16 then
              Printf.eprintf "producer: status msg %d bytes, expected 16\n%!" nbytes;
            Region.store_relaxed recv 0 1;
            let st = Region.msg_replyv rcvid 0 recv 0 1 in
            if st < 0 then
              Layout.die (Printf.sprintf "producer: MsgReplyv errno %d" (-st));
            Printf.printf "producer: consumer status (%d bytes), ack word %d\n%!"
              nbytes (Region.load_relaxed recv 0)
          end else begin
            Printf.printf "producer: receive error %d\n%!" rcvid;
            exit 1
          end
        in
        (push, finish)
  in

  let t0 = Region.monotonic () in
  for seq = 1 to n do
    let payload = seq * 3 in
    Region.store_relaxed msg 0 seq;
    Region.store_relaxed msg 1 payload;
    checksum := !checksum + payload;
    push_qnx ()
  done;
  Region.store_relaxed msg 0 Layout.sentinel;
  Region.store_relaxed msg 1 !checksum;
  push_qnx ();
  finish ();
  let dt = Region.monotonic () -. t0 in
  Printf.printf "producer: %d msgs in %.3fs (%.0f msg/s), checksum %d\n%!"
    n dt (float_of_int n /. dt) !checksum
