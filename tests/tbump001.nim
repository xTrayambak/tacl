import pkg/tacl/alloc/bump

var b: BumpAlloc[512]
let x = b.alloc(32'u64)
let y = b.alloc(32'u64)

echo "free: " & $b.freeChunks
echo "total: " & $b.totalChunks

b.free(x)

echo "free: " & $b.freeChunks
echo "total: " & $b.totalChunks

let z = b.alloc(32'u64)
assert z == x, "Reuse failed"

b.free(z)
let p = b.alloc(256'u64)
assert p != z, "sizeof 256 shouldn't be allocated to sizeof 32 chunk"
