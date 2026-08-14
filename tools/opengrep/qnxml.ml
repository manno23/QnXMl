(* Positive/negative fixtures for tools/opengrep/qnxml.yml (OCaml rules).
   ruleid = must match the immediately-following code line;
   ok     = must NOT match that line.
   Stack only ruleid (or only ok) comments — never interleave before one line.
   Run: make opengrep-test *)

(* --- qnxml-check-then-store-on-shared-word --- *)
let merge_bad t other i =
  let a = Region.load_acq t.s i and b = other.{i} in
  (* ruleid: qnxml-check-then-store-on-shared-word *)
  if b > a then Region.store_rel t.s i b

let merge_ok t other i =
  (* ok: qnxml-check-then-store-on-shared-word *)
  ignore (Region.fetch_add t.s i 1L)

(* --- qnxml-plain-store-to-shared-word (update only; init is ok) --- *)
let update t j value =
  (* ruleid: qnxml-plain-store-to-shared-word *)
  t.s.{j} <- value

let init s ~leaves =
  (* ok: qnxml-plain-store-to-shared-word *)
  s.{0} <- 0L;
  (* ruleid: qnxml-int64-boxing-in-init *)
  s.{1} <- Int64.of_int leaves;
  s

(* --- qnxml-plain-read-of-shared-config (attach only; arena single-owner ok) --- *)
let attach s =
  (* ruleid: qnxml-plain-read-of-shared-config *)
  { cap = Int64.to_int s.{0} }

let attach s ~me =
  (* ruleid: qnxml-plain-read-of-shared-config *)
  { n = Int64.to_int s.{0}; me }

let alloc t =
  (* ok: qnxml-plain-read-of-shared-config *)
  t.free_head <- Int64.to_int t.s.{t.free_head * t.node_words}

(* --- qnxml-shared-counter-truncation --- *)
let push_trunc t =
  (* ruleid: qnxml-shared-counter-truncation *)
  let tail = Int64.to_int (Region.load_acq t.s 0) in
  tail

let push_keep t =
  (* ok: qnxml-shared-counter-truncation *)
  let tail = Region.load_acq t.s 0 in
  tail

(* --- qnxml-int64-boxing-in-hot-path --- *)
let push t x =
  (* ruleid: qnxml-int64-boxing-in-hot-path *)
  Region.store_rel t.s 0 (Int64.of_int x)

let free t i =
  (* ruleid: qnxml-int64-boxing-in-hot-path *)
  t.s.{0} <- Int64.of_int t.free_head

let create s ~capacity =
  (* ruleid: qnxml-int64-boxing-in-init *)
  s.{0} <- Int64.of_int capacity

(* --- qnxml-int64-arith-hot-path --- *)
let mix x =
  (* ruleid: qnxml-int64-arith-hot-path *)
  Int64.add x 0x9E3779B97F4A7C15L

let stage seq =
  (* ruleid: qnxml-int64-boxing-in-hot-path *)
  let boxed = Int64.of_int seq in
  (* ruleid: qnxml-int64-arith-hot-path *)
  Int64.mul boxed 3L

let init s =
  (* ok: qnxml-int64-arith-hot-path *)
  s.{0} <- 0L

(* --- qnxml-pmap-copy-log-heap-alloc --- *)
let copy_node log i =
  (* ruleid: qnxml-pmap-copy-log-heap-alloc *)
  log := i :: !log

let copy_ok log i =
  (* ok: qnxml-pmap-copy-log-heap-alloc *)
  log := [i]

(* --- qnxml-mod-capacity-without-zero-guard --- *)
let slot_base t i =
  (* ruleid: qnxml-mod-capacity-without-zero-guard *)
  (i mod t.cap) * t.width

let slot_ok t i =
  (* ok: qnxml-mod-capacity-without-zero-guard *)
  (i mod t.capacity) * t.width

(* --- qnxml-failwith-runtime-surface --- *)
let alloc_or_die t =
  (* ruleid: qnxml-failwith-runtime-surface *)
  if t.free_head < 0 then failwith "arena exhausted";
  t.free_head

let alloc_result t =
  (* ok: qnxml-failwith-runtime-surface *)
  if t.free_head < 0 then None else Some t.free_head

(* --- qnxml-unlink-before-create-same-name (stale-session generations) --- *)
let producer_stale_name () =
  (* ruleid: qnxml-unlink-before-create-same-name *)
  Region.unlink Layout.shm_name;
  Region.create ~name:Layout.shm_name ~words:Layout.total_words ()

let producer_unique_name session =
  (* ok: qnxml-unlink-before-create-same-name *)
  let name = Layout.shm_name ^ session in
  Region.create ~name ~words:Layout.total_words ()
