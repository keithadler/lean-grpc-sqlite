#!/usr/bin/env bash
# Build the three servers bench/run.sh compares, into run/:
#   kv-lean-server-sqlite-O0   the Lean server with SQLite as leansqlite builds it (no -O flag: -O0)
#   kv-lean-server-sqlite-O2   the same, with SQLite at -O2 (a patch to the local leansqlite checkout)
# and go-baseline/kv-go-server. Needs elan and Go. The leansqlite checkout is put back as it was at the end.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p run
LAKEFILE=.lake/packages/leansqlite/lakefile.lean
lake build kv-lean-server
git -C .lake/packages/leansqlite checkout -q -- lakefile.lean
lake build kv-lean-server
cp .lake/build/bin/kv-lean-server run/kv-lean-server-sqlite-O0
sed -i.orig 's/traceArgs := #\["-fPIC", "-DSQLITE_DISABLE_LFS"/traceArgs := #["-fPIC", "-O2", "-DSQLITE_DISABLE_LFS"/' "$LAKEFILE"
grep -q '"-O2"' "$LAKEFILE" || { echo "could not add -O2 to $LAKEFILE"; exit 1; }
lake build kv-lean-server
cp .lake/build/bin/kv-lean-server run/kv-lean-server-sqlite-O2
mv "$LAKEFILE.orig" "$LAKEFILE"
(cd go-baseline && CGO_ENABLED=1 go build -o kv-go-server . && go build -o kv-check ./cmd/check)
echo "built run/kv-lean-server-sqlite-O0, run/kv-lean-server-sqlite-O2, go-baseline/kv-go-server, go-baseline/kv-check"
