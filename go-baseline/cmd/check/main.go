// check: talks to a kv.KV server with grpc-go and checks the answers, not just the status codes.
package main

import (
	"bytes"
	"context"
	"flag"
	"fmt"
	"os"
	"sync"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"

	"lean-grpc-sqlite/go-baseline/kvpb"
)

var failed int

func check(ok bool, what string) {
	if ok {
		fmt.Println("  ok   ", what)
	} else {
		fmt.Println("  FAIL ", what)
		failed++
	}
}

func main() {
	addr := flag.String("addr", "127.0.0.1:50051", "server")
	flag.Parse()
	conn, err := grpc.NewClient(*addr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		panic(err)
	}
	defer conn.Close()
	kv := kvpb.NewKVClient(conn)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	tag := fmt.Sprint(time.Now().UnixNano())

	_, err = kv.Put(ctx, &kvpb.PutRequest{Key: "k" + tag, Value: []byte("hello")})
	check(err == nil, fmt.Sprintf("Put (%v)", err))
	r, err := kv.Get(ctx, &kvpb.GetRequest{Key: "k" + tag})
	check(err == nil && r.Found && string(r.Value) == "hello", "Get returns what Put stored")

	r, err = kv.Get(ctx, &kvpb.GetRequest{Key: "missing" + tag})
	check(err == nil && !r.Found && len(r.Value) == 0, "Get of a missing key says not found")

	_, err = kv.Put(ctx, &kvpb.PutRequest{Key: "k" + tag, Value: []byte("again")})
	r, _ = kv.Get(ctx, &kvpb.GetRequest{Key: "k" + tag})
	check(err == nil && string(r.Value) == "again", "Put replaces")

	err = conn.Invoke(ctx, "/kv.KV/Delete", &kvpb.GetRequest{Key: "x"}, &kvpb.GetReply{})
	check(status.Code(err) == codes.Unimplemented, fmt.Sprintf("an unknown method is UNIMPLEMENTED (%v)", status.Code(err)))

	big := bytes.Repeat([]byte("0123456789abcdef"), 200*1024/16)
	_, err = kv.Put(ctx, &kvpb.PutRequest{Key: "big" + tag, Value: big})
	r, err2 := kv.Get(ctx, &kvpb.GetRequest{Key: "big" + tag})
	check(err == nil && err2 == nil && bytes.Equal(r.Value, big), "a 200 KB value goes both ways (many frames, flow control)")

	var wg sync.WaitGroup
	var mu sync.Mutex
	bad := 0
	for i := 0; i < 500; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			key := fmt.Sprintf("c%s-%d", tag, i)
			want := []byte(fmt.Sprint(i * i))
			if _, err := kv.Put(ctx, &kvpb.PutRequest{Key: key, Value: want}); err != nil {
				mu.Lock(); bad++; mu.Unlock(); return
			}
			r, err := kv.Get(ctx, &kvpb.GetRequest{Key: key})
			if err != nil || !bytes.Equal(r.Value, want) {
				mu.Lock(); bad++; mu.Unlock()
			}
		}(i)
	}
	wg.Wait()
	check(bad == 0, fmt.Sprintf("500 concurrent Put+Get pairs on one connection all correct (%d wrong)", bad))

	if failed > 0 {
		fmt.Printf("%d check(s) failed\n", failed)
		os.Exit(1)
	}
	fmt.Println("all checks passed")
}
