## A very basic benchmark to stress parts of the allocator that had always bugged me as inefficient.
##
## **NOTE**: requires -d:taclBumpAllocSilentOOM
## **NOTE**: requires `benchy` package

import std/[random, strformat]
import pkg/benchy
import pkg/tacl/alloc/bump

const
  PoolCap = 131072
  Sizes = [8'u64, 16, 24, 32, 48, 64, 128]

var a: BumpAlloc[PoolCap]

randomize(42)

timeIt "5000x small alloc":
  # NOTE: This was to test the previously very inefficient method the allocator used,
  # wherein it kept traversing down the top of the chunks list to find the bottom and to append the newly allocated header to its `next`.
  # Now, that `bottom` is cached and so there's no real need for a O(n) search.
  var stressAlloc: BumpAlloc[1024 * 512]
  for _ in 0 ..< 5000:
    discard stressAlloc.alloc(8)

var liveAllocations: seq[pointer] = @[]

while true:
  let sz = sample(Sizes)
  let p = a.alloc(sz)
  if p == nil:
    break
  liveAllocations.add(p)

liveAllocations.shuffle()
let toFreeCount = liveAllocations.len div 2

for i in 0 ..< toFreeCount:
  free a, liveAllocations[i]

liveAllocations = liveAllocations[toFreeCount .. toFreeCount - 1]

timeIt "allocate fixed against fragmented allocator":
  let p = a.alloc(16)
  if p != nil:
    free a, p

timeIt "churn":
  var churnSlots: array[100, pointer]
  for _ in 0 ..< 10:
    for j in 0 ..< churnSlots.len:
      churnSlots[j] = a.alloc(sample(Sizes))
    for j in countdown(churnSlots.high, 0):
      if churnSlots[j] != nil:
        free a, churnSlots[j]
        churnSlots[j] = nil

debugEcho &"Free / Total: {a.freeChunks} / {a.totalChunks}"
