/-! Protocol Buffers, the wire format gRPC carries: varints, length-delimited fields, and the four messages of
`proto/kv.proto`. Decoding skips fields it does not know, as the format requires, so a newer client still works. -/

namespace GrpcLean.Protobuf

/-- Append `n` as a base-128 varint. -/
def putVarint (out : ByteArray) (n : Nat) : ByteArray := Id.run do
  let mut out := out
  let mut n := n
  while n ≥ 0x80 do
    out := out.push (UInt8.ofNat (n % 0x80 + 0x80))
    n := n / 0x80
  out.push (UInt8.ofNat n)

/-- Append a field's key: its number and wire type. -/
def putKey (out : ByteArray) (field : Nat) (wireType : Nat) : ByteArray :=
  putVarint out (field * 8 + wireType)

/-- Append a length-delimited field (strings, bytes, nested messages). Proto3 leaves out an empty one. -/
def putBytes (out : ByteArray) (field : Nat) (b : ByteArray) : ByteArray :=
  if b.isEmpty then out else putVarint (putKey out field 2) b.size ++ b

/-- Append a bool field. Proto3 leaves out `false`. -/
def putBool (out : ByteArray) (field : Nat) (b : Bool) : ByteArray :=
  if b then (putKey out field 0).push 1 else out

/-- A position in a message being read. -/
structure Reader where
  bytes : ByteArray
  pos : Nat := 0

/-- Read a varint, at most ten bytes. -/
def Reader.varint (r : Reader) : Except String (Nat × Reader) := Id.run do
  let mut n := 0
  let mut shift := 0
  let mut pos := r.pos
  for _ in [0:10] do
    if h : pos < r.bytes.size then
      let b := r.bytes[pos]
      pos := pos + 1
      n := n + (b.toNat % 0x80) * 2 ^ shift
      shift := shift + 7
      if b < 0x80 then
        return .ok (n, { r with pos })
    else
      return .error "truncated varint"
  return .error "varint longer than ten bytes"

/-- Read `len` bytes. -/
def Reader.take (r : Reader) (len : Nat) : Except String (ByteArray × Reader) :=
  if r.pos + len ≤ r.bytes.size then .ok (r.bytes.extract r.pos (r.pos + len), { r with pos := r.pos + len })
  else .error "truncated field"

/-- A field's value, by wire type. -/
inductive Value where
  | varint (n : Nat)
  | fixed64 (b : ByteArray)
  | bytes (b : ByteArray)
  | fixed32 (b : ByteArray)

/-- Every field of a message, in order, as (number, value). Groups (wire types 3 and 4) are refused. -/
def fields (msg : ByteArray) : Except String (Array (Nat × Value)) := do
  let mut r : Reader := { bytes := msg }
  let mut out := #[]
  -- Each field takes at least one byte, so there are at most `msg.size` of them.
  for _ in [0:msg.size] do
    if r.pos ≥ msg.size then break
    let (key, r1) ← r.varint
    let field := key / 8
    if field == 0 then throw "field number 0"
    match key % 8 with
    | 0 => let (n, r2) ← r1.varint; out := out.push (field, .varint n); r := r2
    | 1 => let (b, r2) ← r1.take 8; out := out.push (field, .fixed64 b); r := r2
    | 2 =>
      let (len, r2) ← r1.varint
      let (b, r3) ← r2.take len
      out := out.push (field, .bytes b); r := r3
    | 5 => let (b, r2) ← r1.take 4; out := out.push (field, .fixed32 b); r := r2
    | w => throw s!"unsupported wire type {w}"
  return out

/-- The last occurrence of a length-delimited field, as protobuf's "last one wins"; empty when absent. -/
def bytesField (fs : Array (Nat × Value)) (field : Nat) : Except String ByteArray :=
  fs.foldlM (init := ByteArray.empty) fun acc (n, v) =>
    if n != field then pure acc else
    match v with
    | .bytes b => pure b
    | _ => throw s!"field {field} has the wrong wire type"

/-- A string field: its bytes, which must be UTF-8. -/
def stringField (fs : Array (Nat × Value)) (field : Nat) : Except String String := do
  match String.fromUTF8? (← bytesField fs field) with
  | some s => pure s
  | none => throw s!"field {field} is not UTF-8"

/-- A bool field; `false` when absent. -/
def boolField (fs : Array (Nat × Value)) (field : Nat) : Except String Bool :=
  fs.foldlM (init := false) fun acc (n, v) =>
    if n != field then pure acc else
    match v with
    | .varint k => pure (k != 0)
    | _ => throw s!"field {field} has the wrong wire type"

/-! The messages of `proto/kv.proto`. -/

structure PutRequest where
  key : String
  value : ByteArray

structure PutReply where
  ok : Bool

structure GetRequest where
  key : String

structure GetReply where
  found : Bool
  value : ByteArray

def PutRequest.encode (m : PutRequest) : ByteArray := putBytes (putBytes .empty 1 m.key.toUTF8) 2 m.value
def PutRequest.decode (b : ByteArray) : Except String PutRequest := do
  let fs ← fields b
  return { key := ← stringField fs 1, value := ← bytesField fs 2 }

def PutReply.encode (m : PutReply) : ByteArray := putBool .empty 1 m.ok
def PutReply.decode (b : ByteArray) : Except String PutReply := do
  return { ok := ← boolField (← fields b) 1 }

def GetRequest.encode (m : GetRequest) : ByteArray := putBytes .empty 1 m.key.toUTF8
def GetRequest.decode (b : ByteArray) : Except String GetRequest := do
  return { key := ← stringField (← fields b) 1 }

def GetReply.encode (m : GetReply) : ByteArray := putBytes (putBool .empty 1 m.found) 2 m.value
def GetReply.decode (b : ByteArray) : Except String GetReply := do
  let fs ← fields b
  return { found := ← boolField fs 1, value := ← bytesField fs 2 }

end GrpcLean.Protobuf
