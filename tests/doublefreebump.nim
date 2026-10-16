import pkg/tacl/alloc/bump

var a: BumpAlloc[32]
let p = a.alloc(4)
free a, p
free a, p
