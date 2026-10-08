# lean-grpc-sqlite

A gRPC server written entirely in Lean 4, with SQLite underneath, benchmarked against the same service in Go.

Lean's standard library speaks HTTP/1.1 only, and gRPC needs HTTP/2, so everything between the socket and the
database is written here in Lean:

| File | What it is |
|---|---|
| `GrpcLean/Http2.lean` | HTTP/2 (RFC 9113), cleartext with prior knowledge (`h2c`, which gRPC clients use without TLS): frames, header blocks with CONTINUATION, flow control in both directions, SETTINGS, PING, GOAWAY, RST_STREAM; gRPC's message framing and status trailers on top. |
| `GrpcLean/Hpack.lean` | HPACK (RFC 7541): integer and string literals, the dynamic table, Huffman decoding, and the server's fixed header blocks. |
| `GrpcLean/HpackTables.lean` | HPACK's static and Huffman tables, generated from Go's `golang.org/x/net/http2/hpack` by `scripts/gen-hpack-tables.py`. |
| `GrpcLean/Protobuf.lean` | Protocol Buffers: varints, length-delimited fields, skipping unknown fields, and the messages of `proto/kv.proto`. |
| `GrpcLean/Kv.lean` | The `kv.KV` service (`Put`, `Get`) on SQLite, through [leansqlite](https://github.com/leanprover/leansqlite). |
| `Main.lean` | The server: one task per connection, each with its own SQLite connection. |
| `go-baseline/` | The same service in Go: grpc-go, `database/sql` and mattn/go-sqlite3. `cmd/check` is a correctness checker that drives either server with a real gRPC client. |
| `bench/run.sh` | The benchmark. |

## Building and checking

```bash
lake build                                        # the server and the tests (Lean v4.33.0)
./.lake/build/bin/grpclean_tests                  # protobuf, HPACK (RFC 7541 Appendix C), HTTP/2 framing and flow control
./.lake/build/bin/kv-lean-server --addr 127.0.0.1:50051 --db kv.sqlite
(cd go-baseline && go build -o kv-check ./cmd/check && ./kv-check -addr 127.0.0.1:50051)
```

The checker uses grpc-go's own client, and checks answers, not only status codes: a round trip, a missing key, an
overwrite, an unknown method (`UNIMPLEMENTED`), a 200 KB value in both directions (many frames, and replies bigger
than the client's flow-control window, which go out in parts as the client opens it), and 500 concurrent calls
multiplexed on one connection. Both servers pass all of it.

## The benchmark

`bench/run.sh` (needs [ghz](https://ghz.sh) and Go) starts all three servers on fresh SQLite files, preloads 10,000
keys with 64-byte values, then runs reads (`Get` of a random existing key) and writes (`Put` of a random key) with
ghz. Each run is a 2-second warm-up, thrown away, and 10 seconds measured. Every scenario runs three times on every
server, interleaved so that each round starts with a different server: the machine was not idle (its load average
was around 12), and interleaving spreads that over all three instead of whichever ran when it peaked.

Both servers use SQLite the same way: WAL, `synchronous=NORMAL`, a 5-second busy timeout, one table
(`key TEXT PRIMARY KEY, value BLOB`, `WITHOUT ROWID`) and the same two prepared statements.

### Results

Apple M3 (8 cores), macOS, loopback, ghz on the same machine. Median of three runs, with the range in brackets, in
requests per second; p99 latency is the median run's.

| Scenario | Lean (SQLite -O2) | Go (grpc-go, SQLite -O2) | Lean (SQLite as leansqlite ships it) |
|---|---:|---:|---:|
| `Get`, 1 at a time | 7,623 [7,369–9,658], p99 0.21 ms | **9,717** [9,418–12,507], p99 0.17 ms | 7,575 [7,537–9,525], p99 0.22 ms |
| `Get`, 64 concurrent, 1 connection | **45,105** [44,168–60,809], p99 3.1 ms | 25,649 [23,991–31,738], p99 5.0 ms | 42,148 [34,063–42,989], p99 3.2 ms |
| `Get`, 64 concurrent, 8 connections | **39,511** [28,440–40,043], p99 3.5 ms | 24,869 [16,529–25,260], p99 7.0 ms | 37,691 [30,416–39,093], p99 3.7 ms |
| `Put`, 1 at a time | 7,040 [6,996–7,235], p99 0.24 ms | **9,161** [8,407–9,351], p99 0.18 ms | 7,603 [7,446–7,729], p99 0.21 ms |
| `Put`, 64 concurrent, 8 connections | **32,669** [32,387–33,933], p99 9.1 ms | 23,241 [23,198–24,187], p99 11.8 ms | 29,850 [29,422–30,769], p99 12.4 ms |

`bench/results.json` has every run. Two earlier single passes (`bench/results-run1.json`, `results-run2.json`, run
one server after another) swung by up to a factor of two on the same scenario, which is why the method changed.

### What the numbers say

- **One call at a time, Go is faster**, answering about 30% more calls: its HTTP/2 and protobuf code is mature and heavily
  optimized, and this one is a first version.
- **Under load, the Lean server answers 1.4 to 1.8 times as many calls.** That is mostly design, not language. It
  handles everything one read of the socket delivers, runs those calls, and sends every reply in **one** write, so 64
  calls in flight cost a few system calls instead of dozens. The Go server is idiomatic grpc-go and `database/sql`
  with default settings: a goroutine and its own writes per call, and a connection pool between the calls and
  SQLite. A tuned Go server would close some of the gap; this is the comparison with Go as most people write it.
- **SQLite at `-O0` against `-O2` makes little difference here.** The queries are tiny, so SQLite's own CPU time is
  not what limits them. It would matter for heavier queries.
- **Errors:** a few dozen calls per run end with `Unavailable: use of closed network connection`, on every server.
  They are the calls in flight when ghz stops at the deadline and closes its connections. A fixed-count run of
  50,000 calls has none, on either server.

### A finding along the way

leansqlite compiles SQLite with no `-O` flag, so at `-O0` (see `.lake/packages/leansqlite/.lake/build/sqlite3.o.trace`:
`cc -c ... sqlite3.c -fPIC ...`). Every project that uses it, LeanDB included, runs an unoptimized SQLite. The
`-O2` builds here patch the local copy of its lakefile; `lake update` undoes that.

## What it does not do

- Unary calls only: no client, server or bidirectional streaming.
- No TLS (`h2c` only), no message compression (a compressed request gets `UNIMPLEMENTED`), no deadlines
  (`grpc-timeout` is ignored), no metadata passed to handlers.
- A request body over 1 MiB on one stream would stall: the server never widens a stream's receive window (the
  connection's is 1 GiB and topped up).
- Calls on one connection run one after another, which is fine for SQLite (one writer at a time anyway) and is what
  makes the batching above possible, but a slow call holds up the others on its connection.
- Nothing here is proved. The tests check the pieces against their specifications' own examples, and the checker
  checks the whole against a real client.
