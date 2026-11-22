(** Coalesced wakeups. [owed] is raised by the caller on an
    empty-to-nonempty transition and cleared only when [pulse] returns 0.
    A negative errno (including EAGAIN) leaves the debt set so the caller
    can back off and retry. [send] does not raise. *)

val send : owed:bool ref -> pulse:(unit -> int) -> int
