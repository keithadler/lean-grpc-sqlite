import GrpcLean.HpackTables

/-! HPACK (RFC 7541), HTTP/2's header compression: the decoder a server needs (indexed fields, literals, the dynamic
table, Huffman-coded strings) and the few fixed header blocks a gRPC server sends. -/

namespace GrpcLean.Hpack

/-! ## Huffman decoding

HPACK's Huffman code is canonical: within one code length the codes are consecutive numbers, in byte-value order.
So decoding needs, for each length, the first code, how many codes there are, and which bytes they stand for. -/

structure Canonical where
  /-- For each length 0..30, the first code of that length. -/
  first : Array Nat
  /-- For each length, how many codes have it. -/
  count : Array Nat
  /-- For each length, where its symbols start in `symbols`. -/
  offset : Array Nat
  /-- The byte values, sorted by (length, code). -/
  symbols : Array UInt8

/-- The canonical decoding table, built once from `huffmanCodes` and `huffmanLengths`. -/
def canonical : Canonical := Id.run do
  let pairs := (Array.range 256).map fun i => (huffmanLengths[i]!.toNat, huffmanCodes[i]!.toNat, i)
  let sorted := pairs.qsort fun (l1, c1, _) (l2, c2, _) => l1 < l2 || (l1 == l2 && c1 < c2)
  let mut first := Array.replicate 31 0
  let mut count := Array.replicate 31 0
  let mut offset := Array.replicate 31 0
  let mut seen := Array.replicate 31 false
  for h : k in [0:sorted.size] do
    let (l, c, _) := sorted[k]
    if !seen[l]! then
      first := first.set! l c
      offset := offset.set! l k
      seen := seen.set! l true
    count := count.set! l (count[l]! + 1)
  return { first, count, offset, symbols := sorted.map fun (_, _, s) => UInt8.ofNat s }

/-- Decode a Huffman-coded string. The padding at the end must be fewer than eight bits, all ones (RFC 7541 §5.2). -/
def huffmanDecode (input : ByteArray) : Except String ByteArray := do
  let t := canonical
  let mut out := ByteArray.empty
  let mut code := 0
  let mut len := 0
  for b in input do
    for i in [0:8] do
      let bit := (b.toNat >>> (7 - i)) % 2
      code := code * 2 + bit
      len := len + 1
      if len > 30 then throw "Huffman code longer than 30 bits"
      if len ≥ 5 then
        let f := t.first[len]!
        let n := t.count[len]!
        if n > 0 && code ≥ f && code - f < n then
          out := out.push t.symbols[t.offset[len]! + (code - f)]!
          code := 0
          len := 0
  if len ≥ 8 || code != 2 ^ len - 1 then throw "bad Huffman padding"
  return out

/-- Encode a string with the Huffman code (used by the tests, and by nothing that is sent). -/
def huffmanEncode (input : ByteArray) : ByteArray := Id.run do
  let mut out := ByteArray.empty
  let mut acc := 0
  let mut bits := 0
  for b in input do
    acc := acc * 2 ^ huffmanLengths[b.toNat]!.toNat + huffmanCodes[b.toNat]!.toNat
    bits := bits + huffmanLengths[b.toNat]!.toNat
    while bits ≥ 8 do
      out := out.push (UInt8.ofNat (acc >>> (bits - 8)))
      bits := bits - 8
      acc := acc % 2 ^ bits
  if bits > 0 then
    out := out.push (UInt8.ofNat (acc * 2 ^ (8 - bits) + (2 ^ (8 - bits) - 1)))
  return out

/-! ## Decoding header blocks -/

/-- A connection's decoding state: the dynamic table, newest entry first. -/
structure Decoder where
  dynamic : Array (String × String) := #[]
  size : Nat := 0
  maxSize : Nat := 4096

/-- An entry's size as HPACK counts it. -/
def entrySize (e : String × String) : Nat := e.1.utf8ByteSize + e.2.utf8ByteSize + 32

/-- Evict from the end until the table fits in `maxSize`. -/
def Decoder.evict (d : Decoder) : Decoder := Id.run do
  let mut d := d
  while d.size > d.maxSize && !d.dynamic.isEmpty do
    d := { d with size := d.size - entrySize d.dynamic.back!, dynamic := d.dynamic.pop }
  return d

def Decoder.insert (d : Decoder) (e : String × String) : Decoder :=
  -- An entry bigger than the whole table empties it (RFC 7541 §4.4).
  if entrySize e > d.maxSize then { d with dynamic := #[], size := 0 }
  else ({ d with dynamic := #[e] ++ d.dynamic, size := d.size + entrySize e }).evict

def Decoder.lookup (d : Decoder) (i : Nat) : Except String (String × String) :=
  if i == 0 then .error "index 0"
  else if i ≤ staticTable.size then .ok staticTable[i - 1]!
  else match d.dynamic[i - staticTable.size - 1]? with
    | some e => .ok e
    | none => .error s!"index {i} is past the dynamic table"

/-- A position in a header block. -/
structure Cursor where
  bytes : ByteArray
  pos : Nat := 0

/-- Read an integer with an `n`-bit prefix (RFC 7541 §5.1). -/
def Cursor.int (c : Cursor) (n : Nat) : Except String (Nat × Cursor) := do
  let some b := c.bytes[c.pos]? | throw "truncated integer"
  let mask := 2 ^ n - 1
  let v := b.toNat % 2 ^ n
  if v < mask then return (v, { c with pos := c.pos + 1 })
  let mut value := mask
  let mut shift := 0
  let mut pos := c.pos + 1
  for _ in [0:8] do
    let some b := c.bytes[pos]? | throw "truncated integer"
    pos := pos + 1
    value := value + (b.toNat % 128) * 2 ^ shift
    shift := shift + 7
    if b < 128 then return (value, { c with pos })
  throw "integer too long"

/-- Read a string literal (RFC 7541 §5.2), Huffman-coded or not. -/
def Cursor.string (c : Cursor) : Except String (String × Cursor) := do
  let some b := c.bytes[c.pos]? | throw "truncated string"
  let (len, c) ← c.int 7
  if c.pos + len > c.bytes.size then throw "truncated string"
  let raw := c.bytes.extract c.pos (c.pos + len)
  let raw ← if b ≥ 128 then huffmanDecode raw else pure raw
  let some s := String.fromUTF8? raw | throw "header string is not UTF-8"
  return (s, { c with pos := c.pos + len })

/-- Decode a whole header block into its fields, updating the dynamic table. -/
def Decoder.decode (d : Decoder) (block : ByteArray) : Except String (Array (String × String) × Decoder) := do
  let mut d := d
  let mut c : Cursor := { bytes := block }
  let mut out := #[]
  for _ in [0:block.size] do
    if c.pos ≥ block.size then break
    let b := block[c.pos]!
    if b ≥ 0x80 then
      -- Indexed header field.
      let (i, c1) ← c.int 7
      out := out.push (← d.lookup i)
      c := c1
    else if b ≥ 0x40 then
      -- Literal with incremental indexing.
      let (i, c1) ← c.int 6
      let (name, c2) ← if i == 0 then c1.string else do pure ((← d.lookup i).1, c1)
      let (value, c3) ← c2.string
      out := out.push (name, value)
      d := d.insert (name, value)
      c := c3
    else if b ≥ 0x20 then
      -- Dynamic table size update.
      let (size, c1) ← c.int 5
      if size > 4096 then throw "table size above the 4096 we allow"
      d := ({ d with maxSize := size }).evict
      c := c1
    else
      -- Literal without indexing (0000) or never indexed (0001): same shape.
      let (i, c1) ← c.int 4
      let (name, c2) ← if i == 0 then c1.string else do pure ((← d.lookup i).1, c1)
      let (value, c3) ← c2.string
      out := out.push (name, value)
      c := c3
  return (out, d)

/-! ## What a gRPC server sends

The response headers and trailers never change, except for the status, so they are written once, as literals that
are not added to the client's table (the client then keeps no state for them). -/

/-- A string literal, not Huffman-coded. -/
def literal (s : String) : ByteArray :=
  let b := s.toUTF8
  (if b.size < 127 then ByteArray.empty.push (UInt8.ofNat b.size)
   else Id.run do
     -- Lengths of 127 or more: the 7-bit prefix is full, then base-128 continuation bytes.
     let mut out := ByteArray.empty.push 127
     let mut n := b.size - 127
     while n ≥ 128 do
       out := out.push (UInt8.ofNat (n % 128 + 128))
       n := n / 128
     out.push (UInt8.ofNat n)) ++ b

/-- `:status: 200` (static entry 8) and `content-type: application/grpc` (a literal with static name 31). -/
def responseHeaders : ByteArray :=
  ByteArray.mk #[0x88, 0x0f, 0x10] ++ literal "application/grpc"

/-- The trailers that end a call: `grpc-status`, and a message when it failed. -/
def trailers (status : Nat) (message : String := "") : ByteArray :=
  let st := ByteArray.mk #[0x00] ++ literal "grpc-status" ++ literal (toString status)
  if message.isEmpty then st else st ++ ByteArray.mk #[0x00] ++ literal "grpc-message" ++ literal message

/-- A failed call answered with trailers only, as gRPC allows: `:status: 200`, the content type, and the status. -/
def trailersOnly (status : Nat) (message : String) : ByteArray :=
  responseHeaders ++ trailers status message

end GrpcLean.Hpack
