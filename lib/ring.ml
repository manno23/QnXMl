type t = { s : Region.words; cap : int; width : int }
type error = Bad_geometry

let tail_ix = 0
let head_ix = 8
let cap_ix = 9
let width_ix = 10
let header_words = 11

let words_needed ~slots ~width =
  if slots <= 0 || width <= 0 then 0
  else if slots > (max_int - header_words) / width then 0
  else header_words + (slots * width)

let fits ~slots ~width ~dim =
  slots > 0 && width > 0
  && width <= (max_int - header_words) / slots
  && header_words + slots * width <= dim

let init s ~slots ~width =
  if not (fits ~slots ~width ~dim:(Region.dim_words s)) then Error Bad_geometry
  else begin
    Region.store_relaxed s cap_ix slots;
    Region.store_relaxed s width_ix width;
    Region.store_int s tail_ix 0;
    Region.store_int s head_ix 0;
    Ok { s; cap = slots; width }
  end

let attach s =
  if Region.dim_words s < header_words then Error Bad_geometry
  else
    let cap = Region.load_int s cap_ix in
    let width = Region.load_int s width_ix in
    if not (fits ~slots:cap ~width ~dim:(Region.dim_words s)) then
      Error Bad_geometry
    else Ok { s; cap; width }

let push t src =
  let cap = t.cap in
  let width = t.width in
  let tail = Region.load_int t.s tail_ix in
  let head = Region.load_int t.s head_ix in
  if tail - head >= cap then false
  else
    let b = header_words + (tail mod cap) * width in
    if not (Region.copy_words t.s b src 0 width) then false
    else begin
      Region.store_int t.s tail_ix (tail + 1);
      true
    end

let pop t dst =
  let cap = t.cap in
  let width = t.width in
  let head = Region.load_int t.s head_ix in
  let tail = Region.load_int t.s tail_ix in
  if tail = head then false
  else
    let b = header_words + (head mod cap) * width in
    if not (Region.copy_words dst 0 t.s b width) then false
    else begin
      Region.store_int t.s head_ix (head + 1);
      true
    end

let occupancy t =
  Region.load_int t.s tail_ix - Region.load_int t.s head_ix
