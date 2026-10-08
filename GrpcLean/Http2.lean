import Std.Data.HashMap
import Std.Async.TCP
import GrpcLean.Hpack

/-! HTTP/2 (RFC 9113) as a gRPC server needs it: cleartext with prior knowledge (`h2c`, which is what gRPC clients
use without TLS), frames, header blocks (with CONTINUATION), flow control both ways, SETTINGS, PING and GOAWAY, and
gRPC's message framing and trailers on top. Unary calls only: each request stream carries one message, and gets one
back.

Each connection is served by one task. Everything a read of the socket produces (settings acknowledgements, window
updates, and every response it completed) goes out in one send. -/

namespace GrpcLean.Http2

open Std.Async Std.Async.TCP

/-! ## Frames -/

def frameData : UInt8 := 0x0
def frameHeaders : UInt8 := 0x1
def frameRstStream : UInt8 := 0x3
def frameSettings : UInt8 := 0x4
def framePushPromise : UInt8 := 0x5
def framePing : UInt8 := 0x6
def frameGoaway : UInt8 := 0x7
def frameWindowUpdate : UInt8 := 0x8
def frameContinuation : UInt8 := 0x9

def flagEndStream : UInt8 := 0x1
def flagAck : UInt8 := 0x1
def flagEndHeaders : UInt8 := 0x4
def flagPadded : UInt8 := 0x8
def flagPriority : UInt8 := 0x20

/-- What a client sends first (RFC 9113 §3.4). -/
def preface : ByteArray := "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".toUTF8

def u16 (n : Nat) : ByteArray := ByteArray.mk #[UInt8.ofNat (n >>> 8), UInt8.ofNat n]
def u24 (n : Nat) : ByteArray := ByteArray.mk #[UInt8.ofNat (n >>> 16), UInt8.ofNat (n >>> 8), UInt8.ofNat n]
def u32 (n : Nat) : ByteArray := ByteArray.mk #[UInt8.ofNat (n >>> 24), UInt8.ofNat (n >>> 16), UInt8.ofNat (n >>> 8), UInt8.ofNat n]

def readU24 (b : ByteArray) (i : Nat) : Nat := b[i]!.toNat * 65536 + b[i + 1]!.toNat * 256 + b[i + 2]!.toNat
def readU32 (b : ByteArray) (i : Nat) : Nat :=
  b[i]!.toNat * 16777216 + b[i + 1]!.toNat * 65536 + b[i + 2]!.toNat * 256 + b[i + 3]!.toNat

/-- A frame: the 9-byte header, then the payload. -/
def frame (type flags : UInt8) (stream : Nat) (payload : ByteArray) : ByteArray :=
  u24 payload.size ++ ByteArray.mk #[type, flags] ++ u32 (stream % 2 ^ 31) ++ payload

/-- The settings this server announces: up to 1000 concurrent calls, and a 1 MiB window per call, so a client
  never waits for a window update while sending a request. -/
def ourSettings : ByteArray :=
  frame frameSettings 0 0 (u16 0x3 ++ u32 1000 ++ u16 0x4 ++ u32 1048576)

/-- How far the connection's receive window is opened at the start: from the default 65,535 bytes to 1 GiB. -/
def connectionWindow : Nat := 2 ^ 30

/-! ## Calls -/

/-- The gRPC status codes this server answers with. -/
def statusOk : Nat := 0
def statusInvalidArgument : Nat := 3
def statusUnimplemented : Nat := 12
def statusInternal : Nat := 13

/-- A unary call's outcome: the response message, or a status and a message. -/
abbrev Reply := Except (Nat × String) ByteArray

/-- A method: the request message in, the reply out. -/
abbrev Method := ByteArray → IO Reply

/-- A request stream, as its frames arrive. -/
structure Stream where
  headers : Array (String × String) := #[]
  /-- Header block fragments until END_HEADERS. -/
  block : ByteArray := .empty
  blockEndsStream : Bool := false
  data : ByteArray := .empty
  /-- What this server may still send on the stream (the client's window for it). -/
  sendWindow : Int

/-- A reply being sent: its HEADERS go at once, its message as flow control allows, then its trailers. -/
structure Pending where
  stream : Nat
  /-- The HEADERS frame, until it is sent (headers are not flow-controlled). -/
  headers : ByteArray
  /-- What is left of the gRPC-framed message. -/
  body : ByteArray
  /-- The frame that ends the stream. -/
  trailers : ByteArray

structure Conn where
  sock : Socket.Client
  routes : String → Option Method
  buf : ByteArray := .empty
  prefaceSeen : Bool := false
  decoder : Hpack.Decoder := {}
  streams : Std.HashMap Nat Stream := {}
  /-- The stream whose header block is being continued, if any. -/
  continuing : Option Nat := none
  out : ByteArray := .empty
  /-- What this server may still send on the connection, and what each new stream starts with. -/
  sendWindow : Int := 65535
  peerInitialWindow : Int := 65535
  peerMaxFrame : Nat := 16384
  /-- Bytes received since the connection window was last topped up. -/
  received : Nat := 0
  pending : Array Pending := #[]
  closing : Bool := false

/-- Close the connection with GOAWAY and an error code. -/
def Conn.fail (c : Conn) (code : Nat) (why : String) : Conn :=
  { c with out := c.out ++ frame frameGoaway 0 0 (u32 0 ++ u32 code ++ why.toUTF8), closing := true }

/-- gRPC's framing of one message: a compressed flag (0), the length, the bytes. -/
def grpcMessage (m : ByteArray) : ByteArray := ByteArray.mk #[0] ++ u32 m.size ++ m

/-- A reply, ready to send: an error is trailers only; a message gets headers, the message and the trailers. -/
def replyOf (stream : Nat) (reply : Reply) : Pending :=
  match reply with
  | .error (status, msg) =>
    { stream, headers := .empty, body := .empty,
      trailers := frame frameHeaders (flagEndHeaders ||| flagEndStream) stream (Hpack.trailersOnly status msg) }
  | .ok m =>
    { stream, headers := frame frameHeaders flagEndHeaders stream Hpack.responseHeaders, body := grpcMessage m,
      trailers := frame frameHeaders (flagEndHeaders ||| flagEndStream) stream (Hpack.trailers statusOk) }

/-- Send as much of each waiting reply as flow control allows: the message in DATA frames no bigger than the client
  takes and within both its windows (the connection's and the stream's), then the trailers once all of it is out.
  A reply bigger than the windows goes out in parts, as the client's WINDOW_UPDATEs open them. -/
def Conn.flushPending (c : Conn) : Conn := Id.run do
  let mut c := c
  let mut keep := #[]
  for p in c.pending do
    let mut p := p
    if !p.headers.isEmpty then
      c := { c with out := c.out ++ p.headers }
      p := { p with headers := .empty }
    let mut streamWindow : Int := (c.streams[p.stream]?.map (·.sendWindow)).getD c.peerInitialWindow
    while !p.body.isEmpty && c.sendWindow > 0 && streamWindow > 0 do
      let n := min (min p.body.size c.peerMaxFrame) (min c.sendWindow streamWindow).toNat
      c := { c with out := c.out ++ frame frameData 0 p.stream (p.body.extract 0 n), sendWindow := c.sendWindow - n }
      streamWindow := streamWindow - n
      p := { p with body := p.body.extract n p.body.size }
    if p.body.isEmpty then
      c := { c with out := c.out ++ p.trailers, streams := c.streams.erase p.stream }
    else
      if let some s := c.streams[p.stream]? then
        c := { c with streams := c.streams.insert p.stream { s with sendWindow := streamWindow } }
      keep := keep.push p
  return { c with pending := keep }

/-- Answer a request whose stream has ended: decode the gRPC message, run the method, queue the reply. -/
def Conn.dispatch (c : Conn) (id : Nat) (s : Stream) : IO Conn := do
  let header (n : String) := (s.headers.find? (·.1 == n)).map (·.2)
  let reply : Reply ← do
    match header ":path", header "content-type" with
    | some path, some ct =>
      if !ct.startsWith "application/grpc" then pure (.error (statusInvalidArgument, "content-type is not application/grpc"))
      else match c.routes path with
        | none => pure (.error (statusUnimplemented, s!"unknown method {path}"))
        | some method =>
          let d := s.data
          if d.size < 5 then pure (.error (statusInvalidArgument, "no request message"))
          else if d[0]! != 0 then pure (.error (statusUnimplemented, "compressed messages are not supported"))
          else
            let len := readU32 d 1
            if d.size != 5 + len then pure (.error (statusInvalidArgument, "a unary call carries exactly one message"))
            else
              try method (d.extract 5 d.size)
              catch e => pure (.error (statusInternal, toString e))
    | _, _ => pure (.error (statusInvalidArgument, "missing :path or content-type"))
  return { c with pending := c.pending.push (replyOf id reply) }.flushPending

/-- A complete header block for a stream: decode it in order (HPACK state is per connection), then dispatch if the
  request has no body. -/
def Conn.headerBlock (c : Conn) (id : Nat) (block : ByteArray) (endStream : Bool) : IO Conn := do
  match c.decoder.decode block with
  | .error e => return c.fail 0x9 s!"HPACK: {e}"  -- COMPRESSION_ERROR
  | .ok (headers, decoder) =>
    let s := (c.streams[id]?.getD { sendWindow := c.peerInitialWindow })
    let s := { s with headers := s.headers ++ headers, block := .empty }
    let c := { c with decoder, continuing := none, streams := c.streams.insert id s }
    if endStream then c.dispatch id s else return c

/-- Handle one frame. -/
def Conn.onFrame (c : Conn) (type flags : UInt8) (id : Nat) (p : ByteArray) : IO Conn := do
  if let some cont := c.continuing then
    if type != frameContinuation || id != cont then
      return c.fail 0x1 "expected CONTINUATION"
  -- Strip padding (DATA and HEADERS).
  let unpad (p : ByteArray) : Option ByteArray :=
    if flags &&& flagPadded != 0 then
      if p.size == 0 then none else
      let pad := p[0]!.toNat
      if pad + 1 > p.size then none else some (p.extract 1 (p.size - pad))
    else some p
  if type == frameData then
    if id == 0 then return c.fail 0x1 "DATA on stream 0"
    let some body := unpad p | return c.fail 0x1 "bad padding"
    let c := { c with received := c.received + p.size }
    match c.streams[id]? with
    | none => return c  -- a stream we have finished or reset; its bytes still count for the window
    | some s =>
      let s := { s with data := s.data ++ body }
      let c := { c with streams := c.streams.insert id s }
      if flags &&& flagEndStream != 0 then c.dispatch id s else return c
  else if type == frameHeaders then
    if id == 0 || id % 2 == 0 then return c.fail 0x1 "HEADERS on a stream a client cannot open"
    let some body := unpad p | return c.fail 0x1 "bad padding"
    let body := if flags &&& flagPriority != 0 then body.extract 5 body.size else body
    let endStream := flags &&& flagEndStream != 0
    if flags &&& flagEndHeaders != 0 then c.headerBlock id body endStream
    else
      let s := (c.streams[id]?.getD { sendWindow := c.peerInitialWindow })
      return { c with continuing := some id, streams := c.streams.insert id { s with block := body, blockEndsStream := endStream } }
  else if type == frameContinuation then
    let some s := c.streams[id]? | return c.fail 0x1 "CONTINUATION without HEADERS"
    let block := s.block ++ p
    if flags &&& flagEndHeaders != 0 then c.headerBlock id block s.blockEndsStream
    else return { c with streams := c.streams.insert id { s with block } }
  else if type == frameSettings then
    if flags &&& flagAck != 0 then return c
    if p.size % 6 != 0 then return c.fail 0x6 "SETTINGS length"
    let mut c := c
    for k in [0:p.size / 6] do
      let key := p[6 * k]!.toNat * 256 + p[6 * k + 1]!.toNat
      let v := readU32 p (6 * k + 2)
      if key == 0x4 then
        -- A new initial window changes every open stream's window by the difference.
        let delta : Int := (v : Int) - c.peerInitialWindow
        c := { c with peerInitialWindow := v, streams := c.streams.map fun _ s => { s with sendWindow := s.sendWindow + delta } }
      else if key == 0x5 then
        c := { c with peerMaxFrame := v }
    return { c with out := c.out ++ frame frameSettings flagAck 0 .empty }.flushPending
  else if type == framePing then
    if flags &&& flagAck != 0 then return c
    return { c with out := c.out ++ frame framePing flagAck 0 p }
  else if type == frameWindowUpdate then
    if p.size != 4 then return c.fail 0x6 "WINDOW_UPDATE length"
    let inc : Int := ((readU32 p 0 % 2 ^ 31 : Nat) : Int)
    if id == 0 then return { c with sendWindow := c.sendWindow + inc }.flushPending
    match c.streams[id]? with
    | some s => return { c with streams := c.streams.insert id { s with sendWindow := s.sendWindow + inc } }.flushPending
    | none => return c
  else if type == frameRstStream then
    return { c with streams := c.streams.erase id, pending := c.pending.filter (·.stream != id) }
  else if type == frameGoaway then
    return { c with closing := true }
  else if type == framePushPromise then
    return c.fail 0x1 "a client cannot push"
  else
    return c  -- PRIORITY and unknown frame types are ignored

/-- Handle every complete frame in the buffer; keep the rest for the next read. -/
partial def Conn.drain (c : Conn) : IO Conn := do
  let mut c := c
  if !c.prefaceSeen then
    if c.buf.size < preface.size then return c
    if c.buf.extract 0 preface.size != preface then return c.fail 0x1 "not an HTTP/2 connection preface"
    c := { c with buf := c.buf.extract preface.size c.buf.size, prefaceSeen := true }
  let mut pos := 0
  while pos + 9 ≤ c.buf.size && !c.closing do
    let len := readU24 c.buf pos
    if len > 16384 then
      c := c.fail 0x6 "frame larger than SETTINGS_MAX_FRAME_SIZE"
      break
    if pos + 9 + len > c.buf.size then break
    let type := c.buf[pos + 3]!
    let flags := c.buf[pos + 4]!
    let id := readU32 c.buf (pos + 5) % 2 ^ 31
    let payload := c.buf.extract (pos + 9) (pos + 9 + len)
    pos := pos + 9 + len
    c ← c.onFrame type flags id payload
  c := { c with buf := c.buf.extract pos c.buf.size }
  -- Keep the connection's receive window open: top it up once half of it has been used.
  if c.received ≥ connectionWindow / 2 then
    c := { c with out := c.out ++ frame frameWindowUpdate 0 0 (u32 c.received), received := 0 }
  return c

/-- Serve one connection until the client closes it or it fails.

  Replies are written without waiting for each write to complete: libuv sends a socket's writes in the order they
  were started, so the next read can begin at once. Waiting would cost a hand-off between the event-loop thread and a
  worker on every call, which is most of a call's time when calls come one at a time. The last write is waited for
  before the connection is closed. -/
partial def serveConnection (sock : Socket.Client) (routes : String → Option Method) : Async Unit := do
  sock.noDelay
  let start := ourSettings ++ frame frameWindowUpdate 0 0 (u32 (connectionWindow - 65535))
  let first ← sock.native.send #[start]
  let rec loop (c : Conn) (lastWrite : IO.Promise (Except IO.Error Unit)) : Async Unit := do
    let some chunk ← sock.recv? 65536 | return
    let c ← ({ c with buf := c.buf ++ chunk } : Conn).drain
    let lastWrite ← if c.out.isEmpty then pure lastWrite else sock.native.send #[c.out]
    if c.closing then
      discard <| Async.ofPromise (pure lastWrite)
      sock.shutdown
      return
    loop { c with out := .empty } lastWrite
  loop { sock, routes } first

end GrpcLean.Http2
