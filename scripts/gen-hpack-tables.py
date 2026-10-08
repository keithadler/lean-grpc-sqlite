#!/usr/bin/env python3
"""Write GrpcLean/HpackTables.lean from golang.org/x/net/http2/hpack (RFC 7541 Appendices A and B).

Run from go-baseline/:  python3 ../scripts/gen-hpack-tables.py "$(go list -m -f '{{.Dir}}' golang.org/x/net)"
"""
import re, sys

X = sys.argv[1]
st = open(X + '/http2/hpack/static_table.go').read()
ents = re.findall(r'\{Name: "([^"]*)", Value: "([^"]*)", Sensitive: false\}', st)
assert len(ents) == 61, len(ents)
tb = open(X + '/http2/hpack/tables.go').read()
codes = [int(x, 16) for x in re.findall(r'0x[0-9a-f]+', re.search(r'var huffmanCodes = \[256\]uint32\{(.*?)\n\}', tb, re.S).group(1))]
lens = [int(x) for x in re.findall(r'\d+', re.search(r'var huffmanCodeLen = \[256\]uint8\{(.*?)\n\}', tb, re.S).group(1))]
assert len(codes) == 256 and len(lens) == 256

def lstr(s):
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'

out = ["/-! HPACK's tables (RFC 7541, Appendices A and B), generated from golang.org/x/net/http2/hpack so that they are the",
       'tables a real gRPC client uses. Do not edit by hand: `scripts/gen-hpack-tables.py` writes this file. -/', '',
       'namespace GrpcLean.Hpack', '',
       '/-- The static table, 1-based in HPACK; index 0 here is entry 1. -/',
       'def staticTable : Array (String × String) := #[']
out += ['  (' + lstr(n) + ', ' + lstr(v) + ')' + (',' if i < 60 else '') for i, (n, v) in enumerate(ents)]
out += [']', '', '/-- The Huffman code of each byte value, right-aligned. -/', 'def huffmanCodes : Array UInt32 := #[']
for i in range(0, 256, 8):
    out.append('  ' + ', '.join(hex(c) for c in codes[i:i + 8]) + (',' if i < 248 else ''))
out += [']', '', "/-- The length in bits of each byte value's Huffman code. -/", 'def huffmanLengths : Array UInt8 := #[']
for i in range(0, 256, 16):
    out.append('  ' + ', '.join(str(c) for c in lens[i:i + 16]) + (',' if i < 240 else ''))
out += [']', '', 'end GrpcLean.Hpack', '']
open('../GrpcLean/HpackTables.lean', 'w').write('\n'.join(out))
