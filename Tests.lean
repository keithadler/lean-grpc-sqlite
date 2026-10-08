import GrpcLean

open GrpcLean

/-! Tests: protobuf against hand-worked bytes, HPACK against RFC 7541 Appendix C, and HTTP/2 framing and flow control.
The server end to end, with a real gRPC client, is `go-baseline/cmd/check`. -/

def hex (s : String) : ByteArray := Id.run do
  let digits := (s.toList.filter (· != ' ')).toArray
  let v (c : Char) : Nat := if c.isDigit then c.toNat - '0'.toNat else c.toLower.toNat - 'a'.toNat + 10
  let mut out := ByteArray.empty
  for i in [0:digits.size / 2] do
    out := out.push (UInt8.ofNat (v digits[2 * i]! * 16 + v digits[2 * i + 1]!))
  return out

initialize failures : IO.Ref Nat ← IO.mkRef 0

def check (ok : Bool) (what : String) : IO Unit := do
  if ok then IO.println s!"  ok    {what}"
  else
    IO.println s!"  FAIL  {what}"
    failures.modify (· + 1)

def protobufTests : IO Unit := do
  IO.println "protobuf"
  -- 300 is the varint example in the protobuf documentation: ac 02.
  check (Protobuf.putVarint .empty 300 == hex "ac02") "300 is ac 02"
  let put : Protobuf.PutRequest := { key := "user:42", value := hex "00ff10" }
  check (put.encode == hex "0a07 757365723a3432 1203 00ff10") "PutRequest encodes as the protobuf docs lay it out"
  match Protobuf.PutRequest.decode put.encode with
  | .ok p => check (p.key == "user:42" && p.value == hex "00ff10") "and decodes back"
  | .error e => check false s!"PutRequest decode: {e}"
  -- An unknown field (number 9, varint) before the key is skipped.
  match Protobuf.GetRequest.decode (hex "4801 0a01 61") with
  | .ok g => check (g.key == "a") "an unknown field is skipped"
  | .error e => check false s!"unknown field: {e}"
  check (Protobuf.GetReply.decode (hex "0a05 6869") matches .error _) "a truncated field is refused"
  check ((Protobuf.GetReply.encode { found := false, value := .empty }).isEmpty) "proto3 leaves out default values"
  match Protobuf.GetReply.decode (Protobuf.GetReply.encode { found := true, value := hex "0102" }) with
  | .ok r => check (r.found && r.value == hex "0102") "GetReply round trip"
  | .error e => check false s!"GetReply: {e}"

def hpackTests : IO Unit := do
  IO.println "hpack"
  -- Every byte value through the Huffman code and back: also checks that the code is canonical, as the decoder assumes.
  let all := ByteArray.mk ((Array.range 256).map UInt8.ofNat)
  check (match Hpack.huffmanDecode (Hpack.huffmanEncode all) with | .ok b => b == all | .error _ => false)
    "all 256 byte values survive the Huffman code"
  check (Hpack.huffmanEncode "www.example.com".toUTF8 == hex "f1e3 c2e5 f23a 6ba0 ab90 f4ff") "Huffman of www.example.com (RFC 7541 C.4.1)"
  -- RFC 7541 C.4: three requests on one connection, Huffman-coded, sharing the dynamic table.
  let d0 : Hpack.Decoder := {}
  match d0.decode (hex "8286 8441 8cf1 e3c2 e5f2 3a6b a0ab 90f4 ff") with
  | .error e => check false s!"C.4.1: {e}"
  | .ok (h1, d1) =>
    check (h1 == #[(":method", "GET"), (":scheme", "http"), (":path", "/"), (":authority", "www.example.com")]) "C.4.1 first request"
    check (d1.size == 57) s!"C.4.1 table size 57 ({d1.size})"
    match d1.decode (hex "8286 84be 5886 a8eb 1064 9cbf") with
    | .error e => check false s!"C.4.2: {e}"
    | .ok (h2, d2) =>
      check (h2 == #[(":method", "GET"), (":scheme", "http"), (":path", "/"), (":authority", "www.example.com"), ("cache-control", "no-cache")])
        "C.4.2 second request, using the dynamic table"
      match d2.decode (hex "8287 85bf 4088 25a8 49e9 5ba9 7d7f 8925 a849 e95b b8e8 b4bf") with
      | .error e => check false s!"C.4.3: {e}"
      | .ok (h3, d3) =>
        check (h3 == #[(":method", "GET"), (":scheme", "https"), (":path", "/index.html"), (":authority", "www.example.com"), ("custom-key", "custom-value")])
          "C.4.3 third request"
        check (d3.size == 164) s!"C.4.3 table size 164 ({d3.size})"
  check (Hpack.huffmanDecode (hex "f1e3 c2e5 f23a 6ba0 ab90 f400") matches .error _) "padding that is not all ones is refused"
  -- What the server sends decodes back to what it means.
  match ({} : Hpack.Decoder).decode (Hpack.responseHeaders ++ Hpack.trailers 5 "not found") with
  | .ok (h, _) =>
    check (h == #[(":status", "200"), ("content-type", "application/grpc"), ("grpc-status", "5"), ("grpc-message", "not found")])
      "the server's own header blocks decode as intended"
  | .error e => check false s!"own headers: {e}"

/-- The frames in some bytes, as (type, flags, stream, payload). -/
def framesOf (b : ByteArray) : Array (UInt8 × UInt8 × Nat × ByteArray) := Id.run do
  let mut out := #[]
  let mut pos := 0
  while pos + 9 ≤ b.size do
    let len := Http2.readU24 b pos
    out := out.push (b[pos + 3]!, b[pos + 4]!, Http2.readU32 b (pos + 5) % 2 ^ 31, b.extract (pos + 9) (pos + 9 + len))
    pos := pos + 9 + len
  return out

def http2Tests : IO Unit := do
  IO.println "http2"
  check (Http2.frame Http2.frameSettings 1 0 .empty == hex "000000 04 01 00000000") "an empty SETTINGS ACK is nine bytes"
  check (Http2.frame Http2.frameData 0 3 (hex "abcd") == hex "000002 00 00 00000003 abcd") "a DATA frame on stream 3"
  let sock ← Std.Async.TCP.Socket.Client.mk
  -- A reply bigger than the client's windows goes out in parts, and finishes when a WINDOW_UPDATE opens them.
  let c0 : Http2.Conn := { sock, routes := fun _ => none, sendWindow := 10 }
  let c0 := { c0 with streams := c0.streams.insert 1 { sendWindow := 10 } }
  let c1 := { c0 with pending := #[Http2.replyOf 1 (.ok (ByteArray.mk (Array.replicate 20 7)))] }.flushPending
  let f1 := framesOf c1.out
  check (f1.map (·.1) == #[Http2.frameHeaders, Http2.frameData] && f1[1]!.2.2.2.size == 10 && c1.pending.size == 1)
    "with a 10-byte window, headers and 10 bytes go; the rest waits"
  let c2 ← ({ c1 with out := .empty } : Http2.Conn).onFrame Http2.frameWindowUpdate 0 0 (Http2.u32 100)
  let c3 ← c2.onFrame Http2.frameWindowUpdate 0 1 (Http2.u32 100)
  let f3 := framesOf c3.out
  check (f3.map (·.1) == #[Http2.frameData, Http2.frameHeaders] && f3[0]!.2.2.2.size == 15 && c3.pending.isEmpty
      && f3[1]!.2.1 &&& Http2.flagEndStream != 0)
    "a WINDOW_UPDATE on the connection and the stream lets the other 15 bytes and the trailers out"
  -- Preface, SETTINGS and PING: both get acknowledged, in one batch.
  let ping := hex "0102030405060708"
  let input := Http2.preface ++ Http2.frame Http2.frameSettings 0 0 (Http2.u16 0x4 ++ Http2.u32 1000000) ++ Http2.frame Http2.framePing 0 0 ping
  let c ← ({ sock, routes := fun _ => none, buf := input } : Http2.Conn).drain
  let f := framesOf c.out
  check (f.map (fun x => (x.1, x.2.1)) == #[(Http2.frameSettings, Http2.flagAck), (Http2.framePing, Http2.flagAck)] && f[1]!.2.2.2 == ping)
    "SETTINGS and PING after the preface are both acknowledged"
  check (c.peerInitialWindow == 1000000) "and the client's initial window is taken from its SETTINGS"
  let bad ← ({ sock, routes := fun _ => none, buf := "GET / HTTP/1.1\r\nHost: x\r\n\r\n".toUTF8 } : Http2.Conn).drain
  check (bad.closing && (framesOf bad.out).map (·.1) == #[Http2.frameGoaway]) "an HTTP/1.1 request gets GOAWAY, not a crash"

def main : IO UInt32 := do
  protobufTests
  hpackTests
  http2Tests
  let n ← failures.get
  IO.println (if n == 0 then "all tests passed" else s!"{n} test(s) failed")
  return if n == 0 then 0 else 1
