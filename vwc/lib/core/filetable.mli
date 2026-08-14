(* VWC-RGN-003/004: File Table binds slot indices to file identity + base
   recipe reference resolved from the Head snapshot. Slots are added only by
   the Manager (MSG_ACQUIRE / MSG_OPEN_MORE); Clients treat it read-only. *)

type t

val empty : t
val add : t -> file_id:int64 -> base_recipe:Opref.t -> t * int  (* returns new slot idx *)
val find : t -> int -> (Grant.file_slot, [> `Missing ]) result
val length : t -> int
val to_list : t -> Grant.file_slot list
