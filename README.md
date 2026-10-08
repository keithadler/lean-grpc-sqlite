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
| `bench/build-servers.sh`, `bench/run.sh` | Build the servers, and run the benchmark. |

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

`bench/build-servers.sh` builds the three servers (needs elan and Go), then `bench/run.sh` (needs
[ghz](https://ghz.sh)) starts all three on fresh SQLite files, preloads 10,000
keys with 64-byte values, then runs reads (`Get` of a random existing key) and writes (`Put` of a random key) with
ghz. Each run is a 2-second warm-up, thrown away, and 10 seconds measured. Every scenario runs three times on every
server, interleaved so that each round starts with a different server: the machine was not idle (its load average
was around 12), and interleaving spreads that over all three instead of whichever ran when it peaked.

Both servers use SQLite the same way: WAL, `synchronous=NORMAL`, a 5-second busy timeout, one table
(`key TEXT PRIMARY KEY, value BLOB`, `WITHOUT ROWID`) and the same two prepared statements.

### Results

Apple M3 (8 cores), macOS, loopback, ghz on the same machine. Median of three runs, with the range in brackets, in
requests per second; p99 latency is the median run's. The machine was busy (other work raised its load average), so
compare the columns of one table, not numbers across runs.

| Scenario | Lean (SQLite -O2) | Go (grpc-go, SQLite -O2) | Lean (SQLite as leansqlite ships it) |
|---|---:|---:|---:|
| `Get`, 1 at a time | **7,251** [6,153–7,354], p99 0.20 ms | 7,084 [6,557–7,329], p99 0.27 ms | 6,799 [6,425–7,112], p99 0.25 ms |
| `Get`, 64 concurrent, 1 connection | **31,030** [30,308–32,754], p99 4.6 ms | 19,253 [17,877–29,877], p99 7.2 ms | 33,269 [30,376–33,518], p99 4.2 ms |
| `Get`, 64 concurrent, 8 connections | **32,100** [26,481–48,278], p99 4.6 ms | 19,803 [17,830–30,557], p99 9.6 ms | 31,255 [26,918–47,640], p99 4.7 ms |
| `Put`, 1 at a time | 7,885 [7,824–9,994], p99 0.19 ms | **8,649** [7,868–10,570], p99 0.19 ms | 7,884 [7,309–10,198], p99 0.17 ms |
| `Put`, 64 concurrent, 8 connections | **25,456** [24,782–38,379], p99 11.3 ms | 17,817 [17,809–26,266], p99 15.3 ms | 22,501 [22,298–33,240], p99 21.5 ms |

`bench/results.json` has every run. Two earlier single passes (`bench/results-run1.json`, `results-run2.json`, run
one server after another, with the first version of the server) swung by up to a factor of two on the same scenario,
which is why the method changed.

### What the numbers say

- **One call at a time, it is close:** reads are even, and Go answers about 10% more writes. The first version of this
  server was 20 to 40% behind here. Profiling showed its time went almost entirely to threads waiting on each
  other, not to its own code: Lean's async I/O runs on an event-loop thread, and every `await` is a hand-off between
  that thread and a worker. It waited for each reply's write to finish before reading the next request; now it
  starts the write and reads at once (libuv sends a socket's writes in order). Head to head in one interleaved run,
  that took one-at-a-time reads from 6,787 to 7,816 and writes from 5,932 to 7,364 (`bench/results-ab.json`).
- **Under load, the Lean server answers 1.4 to 1.6 times as many calls.** That is mostly design, not language. It
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
`cc -c ... sqlite3.c -fPIC ...`). Every project that uses it, LeanDB included, runs an unoptimized SQLite.
`bench/build-servers.sh` builds the `-O2` variant by patching the local leansqlite checkout for one build and
putting it back. The cause is Lake's `buildO`, which adds no optimization flag: reported as
[leanprover/leansqlite#54](https://github.com/leanprover/leansqlite/issues/54) and
[leanprover/lean4#15548](https://github.com/leanprover/lean4/issues/15548).

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
