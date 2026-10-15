## A very simple bump allocator utilizing the stack.
## It can reclaim and recycle memory blocks.
##
## It is mostly meant for substituting a real allocator in a place where:
## a) an allocator cannot be afforded, or
## b) an unstable environment like a hacky shim-layer
##
## Copyright (C) 2026 Trayambak Rai (xtrayambak@disroot.org)

const
  UseLibcMemMethods = not defined(taclBumpAllocDontUseLibcMethods)
  OOMCausesPanic = not defined(taclBumpAllocSilentOOM)

type
  Chunk = object
    ## Internal type, this is used to track chunks in the allocator. It's basically a header.
    ## It too lives in the bump allocator pool :^)
    size: uint64
    free: uint8
      # OPTIMIZE: Surely we could use some cheap trick to merge this into something else?
    next: ptr Chunk

  BumpAlloc*[N: static int] = object
    pool {.align: 16.}: array[N, uint8]
      # It's better to align the pool, as sometimes when you give memory from here to code that expects proper alignment for stuff like SIMD, it immediately dies.
    pos: uint64 # The current position at which the allocator is standing

    chunks: ptr Chunk # The current list of chunks 

const ChunkSize = cast[uint64](sizeof(Chunk))

func reset*[N: static int](bump: var BumpAlloc[N]) =
  ## Reset the allocator back to its original state, and also wipe out all data contained within.
  bump.pos = 0'u64

  when UseLibcMemMethods:
    zeroMem(bump.pool[0].addr, N)
  else:
    # For environments where memset() isn't available, or the environment is too unstable to invoke it. *cough cough*, like my wonderful projects.
    for i in 0 ..< N:
      bump.pool[i] = 0'u8

  bump.chunks = nil

func front*[N: static int](bump: BumpAlloc[N]): pointer {.inline, raises: [].} =
  ## Get the pointer to the start of the allocator pool.
  bump.pool[0].addr

func back*[N: static int](bump: BumpAlloc[N]): pointer {.inline, raises: [].} =
  ## Get the pointer to the back of the allocator pool, that is, the end.
  bump.pool[N - 1].addr

func allocRaw*[N: static int](
    bump: var BumpAlloc[N], size: uint64
): pointer {.inline, raises: [].} =
  ## Allocate a chunk of `size` on the allocator.
  ## It is not tracked.
  let chunk = bump.pool[bump.pos].addr
  bump.pos += size

  if bump.pos >= cast[uint64](N):
    return nil

  chunk

func findFreeChunk[N: static int](
    bump: var BumpAlloc[N], size: uint64
): ptr Chunk {.inline, raises: [].} =
  # TODO: Maybe we could eventually collapse two contiguous chunks adding up to
  # `size` bytes into a single one eventually? That sounds nice.
  var freeChunk = bump.chunks
  while freeChunk != nil:
    if freeChunk.free == 1'u8 and freeChunk.size == size:
      return freeChunk

    freeChunk = freeChunk.next

  nil

func alloc*[N: static int](
    bump: var BumpAlloc[N], size: uint64
): pointer {.raises: [].} =
  ## Allocate a chunk of `size` on the allocator.
  ## It is tracked.

  let reusedChunk = bump.findFreeChunk(size)
  if reusedChunk != nil:
    # if we found a reusable chunk, nice. we'll just mark it used
    reusedChunk.free = 0'u8
    return cast[pointer](cast[uint64](reusedChunk) + ChunkSize)

  # else, we'll have to allocate a new chunk
  let buffer = bump.allocRaw(size + ChunkSize)
  if buffer == nil and OOMCausesPanic:
    raise newException(OutOfMemDefect, "Out of memory in bump allocator")

  let chunk = cast[ptr Chunk](buffer)

  chunk.size = size
  chunk.free = 0'u8

  if bump.chunks != nil:
    var curr = bump.chunks
    while curr.next != nil:
      curr = curr.next

    curr.next = chunk
  else:
    bump.chunks = chunk

  cast[pointer](cast[uint64](buffer) + ChunkSize)

func free*[N: static int](bump: BumpAlloc[N], buffer: pointer) {.inline, raises: [].} =
  ## Deallocate a chunk allocated via this bump allocator.
  ##
  ## **Note**: There's no real deallocation occurring here. No memory can be reclaimed by the kernel. The chunk simply becomes available for subsequent allocations.
  ## 
  ## **Note**: This ensures that the buffer was, indeed, allocated by the bump allocator.
  ##           If that is not true, then it simply turns into a no-op.
  if buffer < bump.front() or buffer > bump.back():
    # If the buffer wasn't allocated on this allocator's pool, ignore it.
    return

  # we basically need to mark this chunk free. that's it.
  let header = cast[ptr Chunk](cast[uint64](buffer) - ChunkSize)
  header.free = 1'u8

func freeChunks*[N: static int](bump: BumpAlloc[N]): uint64 {.raises: [].} =
  ## Count the number of chunks that are currently marked as free.
  var n: uint64

  var curr = bump.chunks
  while curr != nil:
    if curr.free == 1'u8:
      inc n

    curr = curr.next

  n

func totalChunks*[N: static int](bump: BumpAlloc[N]): uint64 {.raises: [].} =
  ## Count the number of chunks that are currently allocated.
  var n: uint64

  var curr = bump.chunks
  while curr != nil:
    curr = curr.next
    inc n

  n
