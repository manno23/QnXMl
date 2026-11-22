(** Deadline loop for startup handshakes. [Again] retries until [now]
    reaches [deadline]; [Stop] returns immediately. The clock is injected
    so tests can drive it without sleeping. *)

type ('a, 'e) step =
  | Done of 'a
  | Again
  | Stop of 'e

val until :
  now:(unit -> 'c) ->
  deadline:'c ->
  wait:(unit -> unit) ->
  f:(unit -> ('a, 'e) step) ->
  ('a, [ `deadline | `stop of 'e ]) result
