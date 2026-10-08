import GrpcLean

open Std.Async Std.Async.TCP GrpcLean

/-- `kv-lean-server [--addr 127.0.0.1:50051] [--db kv-lean.sqlite]`: serve `kv.KV` over gRPC until killed. -/
def main (args : List String) : IO Unit := do
  let rec opt (name : String) (dflt : String) : List String → String
    | a :: b :: rest => if a == name then b else opt name dflt (b :: rest)
    | _ => dflt
  let addr := opt "--addr" "127.0.0.1:50051" args
  let db := opt "--db" "kv-lean.sqlite" args
  let some (host, port) := (match addr.splitOn ":" with
      | [h, p] => p.toNat?.map (h, ·)
      | _ => none) | throw (IO.userError s!"--addr must be host:port, not {addr}")
  let some ip := Std.Net.IPv4Addr.ofString host | throw (IO.userError s!"{host} is not an IPv4 address")
  -- Created up front, so a bad path fails here rather than on the first connection.
  discard <| Kv.Store.open db
  Async.block do
    let server ← Socket.Server.mk
    server.bind (.v4 { addr := ip, port := port.toUInt16 })
    server.listen 1024
    IO.eprintln s!"lean kv server on {addr}"
    while true do
      let client ← server.accept
      background do
        let store ← Kv.Store.open db
        Http2.serveConnection client (Kv.routes store)
