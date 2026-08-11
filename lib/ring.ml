(* Bounded single-producer/single-consumer ring over a region slice.

   Layout (word indices within the slice):
     0   : tail  — total slots ever pushed  (written by producer only)
     1–7 : padding
     8   : head  — total slots ever popped  (written by consumer only)
     9   : capacity in slots (read-only after init)
     10  : slot width in words (read-only after init)
     11… : capacity * width payload words

   head sits at word 8, so the two hot counters live on separate 64-byte
   cache lines (a Cortex-A76 line is 8 int64 words). With the producer
   and consumer pinned to different cores, a push no longer invalidates
   the consumer's line and vice versa — the false-sharing fix of SPEC A.5.
   Words 9 and 10 are written once by [init] and read-only afterwards, so
   they share head's line harmlessly. [words_needed] accounts for the pad.

   Monotone counters (never wrapped) make full/empty tests exact:
   full  = tail - head = capacity, empty = tail = head.
   The producer's release-store of tail publishes the payload writes;
   the consumer's acquire-load of tail is the matching fence — the only
   synchronization the structure needs, done in the C stubs. *)

type t = { s : Region.words; cap : int; width : int }

let tail_ix = 0        (* producer writes this word (cache line 0)       *)
let head_ix = 8        (* consumer writes this word (cache line 1)       *)
let cap_ix = 9         (* read-only after init                          *)
let width_ix = 10      (* read-only after init                          *)
let header_words = 11  (* 2 hot counters + 7 pad + 2 read-only config    *)

let words_needed ~slots ~width = header_words + (slots * width)

let init s ~slots ~width =
  s.{cap_ix} <- Int64.of_int slots;
  s.{width_ix} <- Int64.of_int width;
  Region.store_rel s tail_ix 0L;
  Region.store_rel s head_ix 0L;
  { s; cap = slots; width }

let attach s =
  { s; cap = Int64.to_int s.{cap_ix}; width = Int64.to_int s.{width_ix} }

let slot_base t i = header_words + (i mod t.cap) * t.width

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
