let send ~owed ~pulse =
  if not !owed then 0
  else
    let rc = pulse () in
    if rc = 0 then owed := false;
    rc

type attempt =
  | Awake
  | Pulsed
  | Again of int

(* Consumer protocol, release/acquire on the shared [asleep] word:
     store_rel asleep 1
     if ring nonempty then store asleep 0 else MsgReceive; store asleep 0
   Producer, after the push that release-stores the ring tail:
     [arm] CAS-es asleep from 1 to 0 and pulses once.
   A consumer that observed empty did so after publishing asleep=1, so a
   producer that already pushed either sees the flag and pulses, or its
   tail store is visible to the consumer's recheck. EAGAIN puts the flag
   back so the debt is not dropped. *)
let arm ~load ~cas ~pulse =
  if load () <> 1 then Awake
  else if not (cas 1 0) then Awake
  else
    let rc = pulse () in
    if rc = 0 then Pulsed
    else begin
      ignore (cas 0 1);
      Again rc
    end
