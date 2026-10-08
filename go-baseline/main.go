// The baseline: the same KV service as the Lean server, in Go with grpc-go and SQLite (mattn/go-sqlite3,
// the same C SQLite), set up the same way: WAL, synchronous=NORMAL, prepared statements.
package main

import (
	"context"
	"database/sql"
	"flag"
	"log"
	"net"

	_ "github.com/mattn/go-sqlite3"
	"google.golang.org/grpc"

	"lean-grpc-sqlite/go-baseline/kvpb"
)

type server struct {
	kvpb.UnimplementedKVServer
	put *sql.Stmt
	get *sql.Stmt
}

func (s *server) Put(ctx context.Context, r *kvpb.PutRequest) (*kvpb.PutReply, error) {
	if _, err := s.put.ExecContext(ctx, r.Key, r.Value); err != nil {
		return nil, err
	}
	return &kvpb.PutReply{Ok: true}, nil
}

func (s *server) Get(ctx context.Context, r *kvpb.GetRequest) (*kvpb.GetReply, error) {
	var v []byte
	err := s.get.QueryRowContext(ctx, r.Key).Scan(&v)
	if err == sql.ErrNoRows {
		return &kvpb.GetReply{Found: false}, nil
	}
	if err != nil {
		return nil, err
	}
	return &kvpb.GetReply{Found: true, Value: v}, nil
}

func main() {
	addr := flag.String("addr", "127.0.0.1:50052", "address to listen on")
	path := flag.String("db", "kv-go.sqlite", "SQLite file")
	flag.Parse()
	db, err := sql.Open("sqlite3", *path+"?_journal_mode=WAL&_synchronous=NORMAL&_busy_timeout=5000")
	if err != nil {
		log.Fatal(err)
	}
	if _, err := db.Exec("CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value BLOB NOT NULL) WITHOUT ROWID"); err != nil {
		log.Fatal(err)
	}
	put, err := db.Prepare("INSERT INTO kv (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value")
	if err != nil {
		log.Fatal(err)
	}
	get, err := db.Prepare("SELECT value FROM kv WHERE key = ?")
	if err != nil {
		log.Fatal(err)
	}
	lis, err := net.Listen("tcp", *addr)
	if err != nil {
		log.Fatal(err)
	}
	s := grpc.NewServer()
	kvpb.RegisterKVServer(s, &server{put: put, get: get})
	log.Printf("go kv server on %s", *addr)
	log.Fatal(s.Serve(lis))
}
