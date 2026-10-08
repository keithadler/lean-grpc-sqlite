import SQLite
import GrpcLean.Protobuf
import GrpcLean.Http2

/-! The `kv.KV` service of `proto/kv.proto`, kept in SQLite. Each connection gets its own SQLite connection (WAL
mode, so reads do not wait for writers), with its statements prepared once. Set up as the Go baseline is: WAL,
`synchronous=NORMAL`, a 5-second busy timeout, the same table and the same two statements. -/

namespace GrpcLean.Kv

open Protobuf

structure Store where
  db : SQLite
  put : SQLite.Stmt
  get : SQLite.Stmt

/-- Open the database (creating the table if needed) and prepare the two statements. -/
def Store.open (path : System.FilePath) : IO Store := do
  let db ← SQLite.open path (busyTimeoutMs := 5000)
  db.exec "PRAGMA journal_mode=WAL"
  db.exec "PRAGMA synchronous=NORMAL"
  db.exec "CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value BLOB NOT NULL) WITHOUT ROWID"
  let put ← db.prepare "INSERT INTO kv (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value"
  let get ← db.prepare "SELECT value FROM kv WHERE key = ?"
  return { db, put, get }

def Store.putValue (s : Store) (key : String) (value : ByteArray) : IO Unit := do
  s.put.reset
  s.put.bindText 1 key
  s.put.bindBlob 2 value
  discard s.put.step

def Store.getValue (s : Store) (key : String) : IO (Option ByteArray) := do
  s.get.reset
  s.get.bindText 1 key
  if ← s.get.step then return some (← s.get.columnBlob 0) else return none

/-- The service's methods, by gRPC path. -/
def routes (s : Store) : String → Option Http2.Method
  | "/kv.KV/Put" => some fun bytes => do
    match PutRequest.decode bytes with
    | .error e => return .error (Http2.statusInvalidArgument, e)
    | .ok r =>
      s.putValue r.key r.value
      return .ok (PutReply.encode { ok := true })
  | "/kv.KV/Get" => some fun bytes => do
    match GetRequest.decode bytes with
    | .error e => return .error (Http2.statusInvalidArgument, e)
    | .ok r =>
      match ← s.getValue r.key with
      | some v => return .ok (GetReply.encode { found := true, value := v })
      | none => return .ok (GetReply.encode { found := false, value := .empty })
  | _ => none

end GrpcLean.Kv
