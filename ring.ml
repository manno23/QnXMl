(* Bounded single-producer/single-consumer ring over a region slice.

   Layout (word indices within the slice):
     0 : tail  — total slots ever pushed  (written by producer only)
     1 : head  — total slots ever popped  (written by consumer only)
     2 : capacity in slots
     3 : slot width in words
     4… : capacity * width payload words

   Monotone counters (never wrapped) make full/empty tests exact:
   full  = tail - head = capacity, empty = tail = head.
   The producer's release-store of tail publishes the payload writes;
   the consumer's acquire-load of tail is the matching fence — the only
   synchronization the structure needs, done in the C stubs. *)

type t = { s : Region.words; cap : int; width : int }

let tail_ix = 0
let head_ix = 1

let words_needed ~slots ~width = 4 + (slots * width)

let init s ~slots ~width =
  s.{2} <- Int64.of_int slots;
  s.{3} <- Int64.of_int width;
  Region.store_rel s tail_ix 0L;
  Region.store_rel s head_ix 0L;
  { s; cap = slots; width }

let attach s =
  { s; cap = Int64.to_int s.{2}; width = Int64.to_int s.{3} }

let slot_base t i = 4 + (i mod t.cap) * t.width

(* [push t payload] copies [width] words in; false if full. *)
let push t (payload : Region.words) =
  let tail = Int64.to_int (Region.load_acq t.s tail_ix) in
  let head = Int64.to_int (Region.load_acq t.s head_ix) in
  if tail - head >= t.cap then false
  else begin
    let b = slot_base t tail in
    for i = 0 to t.width - 1 do t.s.{b + i} <- payload.{i} done;
    Region.store_rel t.s tail_ix (Int64.of_int (tail + 1));
    true
  end

(* [pop t out] copies one slot into [out]; false if empty. *)
let pop t (out : Region.words) =
  let head = Int64.to_int (Region.load_acq t.s head_ix) in
  let tail = Int64.to_int (Region.load_acq t.s tail_ix) in
  if tail = head then false
  else begin
    let b = slot_base t head in
    for i = 0 to t.width - 1 do out.{i} <- t.s.{b + i} done;
    Region.store_rel t.s head_ix (Int64.of_int (head + 1));
    true
  end

let occupancy t =
  Int64.to_int (Region.load_acq t.s tail_ix)
  - Int64.to_int (Region.load_acq t.s head_ix)
