## A very simple bump allocator.
## It can reclaim and recycle memory blocks.
##
## It is mostly meant for substituting a real allocator in a place where:
## a) you have a massive area of memory (e.g for guest code)
## b) an allocator cannot be afforded, or
## c) an unstable environment like a hacky shim-layer
##
## **NOTE**: It is up to the programmer to deallocate the backing pool. As `BumpExternalAlloc` is not aware of where its pool was sourced from, it will obviously make no attempts to do so itself.
##
## Copyright (C) 2026 Trayambak Rai (xtrayambak@disroot.org)
import std/options

const
  UseLibcMemMethods* = not defined(taclBumpExternalAllocDontUseLibcMethods)
    ## If enabled, then this allocator will attempt to avoid utilizing any C standard library methods directly (e.g `zeroMem`, which translates down to a `memset`).

  OOMCausesPanic* = not defined(taclBumpExternalAllocSilentOOM)
    ## If enabled, then this allocator will simply make its front-facing allocation routines silently return `nil` instead of causing a defect and aborting.

type
  Chunk = object
    ## Internal type, this is used to track chunks in the allocator. It's basically a header.
    ## It too lives in the bump allocator pool :^)
    size: uint64
    free: uint8
      # OPTIMIZE: Surely we could use some cheap trick to merge this into something else?
    next: ptr Chunk

  BumpExternalAlloc* = object
    pool: ptr UncheckedArray[uint8]
    pos: uint64 ## The current position at which the allocator is standing
    size: uint64

    chunks: ptr Chunk ## The current list of chunks 
    bottom: ptr Chunk ## Cached bottom of the list of chunks

    freeChunks: uint64

const ChunkSize = cast[uint64](sizeof(Chunk))

func reset*(bump: var BumpExternalAlloc) =
  ## Reset the allocator back to its original state, and also wipe out all data contained within.
  bump.pos = 0'u64

  when UseLibcMemMethods:
    zeroMem(bump.pool[0].addr, bump.size)
  else:
    # For environments where memset() isn't available, or the environment is too unstable to invoke it. *cough cough*, like my wonderful projects.
    for i in 0 ..< bump.size:
      bump.pool[i] = 0'u8

  bump.chunks = nil
  bump.bottom = nil
  bump.freeChunks = 0'u64

func front*(bump: BumpExternalAlloc): pointer {.inline, raises: [].} =
  ## Get the pointer to the start of the allocator pool.
  cast[pointer](bump.pool)

func back*(bump: BumpExternalAlloc): pointer {.inline, raises: [].} =
  ## Get the pointer to the back of the allocator pool, that is, the end.
  bump.pool[bump.size - 1].addr

func allocRaw*(
    bump: var BumpExternalAlloc, size: uint64
): pointer {.inline, raises: [].} =
  ## Allocate a chunk of `size` on the allocator.
  ## It is not tracked.
  let chunk = bump.pool[bump.pos].addr
  bump.pos += size

  if bump.pos >= cast[uint64](bump.size):
    return nil

  chunk

func findFreeChunk(
    bump: var BumpExternalAlloc, size: uint64
): ptr Chunk {.inline, raises: [].} =
  if bump.freeChunks == 0'u64:
    # If we do not have any free tracked chunks, there is no point in traversing
    # down the `chunks` list to find any.
    return nil

  # TODO: Maybe we could eventually collapse two contiguous chunks adding up to
  # `size` bytes into a single one eventually? That sounds nice.
  var freeChunk = bump.chunks
  while freeChunk != nil:
    if freeChunk.free == 1'u8 and freeChunk.size == size:
      return freeChunk

    freeChunk = freeChunk.next

  nil

func alloc*(bump: var BumpExternalAlloc, size: uint64): pointer {.raises: [].} =
  ## Allocate a chunk of `size` on the allocator.
  ## It is tracked.

  let reusedChunk = bump.findFreeChunk(size)
  if reusedChunk != nil:
    # if we found a reusable chunk, nice. we'll just mark it used
    reusedChunk.free = 0'u8
    dec bump.freeChunks
    return cast[pointer](cast[uint64](reusedChunk) + ChunkSize)

  # else, we'll have to allocate a new chunk
  let buffer = bump.allocRaw(size + ChunkSize)
  if buffer == nil:
    when OOMCausesPanic:
      raise newException(OutOfMemDefect, "Out of memory in bump allocator")

    return nil

  let chunk = cast[ptr Chunk](buffer)

  chunk.size = size
  chunk.free = 0'u8
  chunk.next = nil

  if bump.bottom != nil:
    # OPTIMIZATION: If we have a specified bottom, write directly to its `next` field.
    # If we do not, then we probably haven't allocated a buffer as of yet.
    bump.bottom.next = chunk

  if bump.chunks == nil:
    # We (probably) are the very first allocation. Begin this list so that other routines
    # that traverse it work properly.
    bump.chunks = chunk

  # We are now the bottom.
  bump.bottom = chunk

  cast[pointer](cast[uint64](buffer) + ChunkSize)

func alignedAlloc*(
    bump: var BumpExternalAlloc, alignment: uint64, size: uint64
): pointer {.raises: [].} =
  ## Allocate a chunk of `size` bytes and `alignment` on the allocator.
  ## It is tracked.

  let
    baseAddr = cast[uint64](bump.pool) + bump.pos
    unpaddedAddr = baseAddr + ChunkSize

    remainder = unpaddedAddr and (alignment - 1'u64)
    padding =
      if remainder == 0'u64:
        0'u64
      else:
        alignment - remainder

    totalSize = size + padding

  let buffer = bump.allocRaw(totalSize + ChunkSize)
  if buffer == nil:
    when OOMCausesPanic:
      raise newException(OutOfMemDefect, "Out of memory in bump allocator")

    return nil

  let
    chunkAddr = cast[uint64](buffer) + padding
    chunk = cast[ptr Chunk](chunkAddr)

  chunk.size = size
  chunk.free = 0'u8
  chunk.next = nil

  if bump.bottom != nil:
    # OPTIMIZATION: If we have a specified bottom, write directly to its `next` field.
    # If we do not, then we probably haven't allocated a buffer as of yet.
    bump.bottom.next = chunk

  if bump.chunks == nil:
    # We (probably) are the very first allocation. Begin this list so that other routines
    # that traverse it work properly.
    bump.chunks = chunk

  # We are now the bottom.
  bump.bottom = chunk

  cast[pointer](chunkAddr + ChunkSize)

func free*(bump: var BumpExternalAlloc, buffer: pointer) {.inline, raises: [].} =
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

  inc bump.freeChunks

func usableSize*(bump: BumpExternalAlloc, buffer: pointer): Option[uint64] =
  ## Find the usable size of a particular allocated memory chunk.
  ##
  ## **Note**: This ensures that the buffer was actually allocated on this allocator's pool.
  ##          If that is not true, then this will cause undefined behaviour.
  ##
  ## **Note**: This expects the exact value of the absolute start of the chunk.
  ##          Even a minor drift _can_ and _will_ cause undefined behaviour, and this
  ##          routine makes _no_ attempt to guard against it. Ideally, we should scan
  ##          over every tracked chunk and its ranges to find the containing one.
  if buffer < bump.front() or buffer > bump.back():
    # If the buffer wasn't allocated on this allocator's pool, return an empty optional.
    return none(uint64)

  let header = cast[ptr Chunk](cast[uint64](buffer) - ChunkSize)
  some(header.size)

func freeChunks*(bump: BumpExternalAlloc): uint64 {.inline, raises: [].} =
  ## Count the number of chunks that are currently marked as free.
  bump.freeChunks

func totalChunks*(bump: BumpExternalAlloc): uint64 {.raises: [].} =
  ## Count the number of chunks that are currently allocated.
  var n: uint64

  var curr = bump.chunks
  while curr != nil:
    curr = curr.next
    inc n

  n

func newBumpExternalAllocator*(
    pool: pointer | ptr uint8 | ptr UncheckedArray[uint8], size: uint64
): BumpExternalAlloc =
  BumpExternalAlloc(pool: cast[ptr UncheckedArray[uint8]](pool), size: size, pos: 0'u64)
