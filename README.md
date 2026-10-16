# tacl
Tray's Awesome Common Library is a set of utilities that are used across many of my projects.

## tacl/alloc/bump
An OS-agnostic intrusive allocator (yes, it's _not quite_ a pure bump allocator) for when you need a quick-and-dirty allocator.

## tacl/alloc/bump_ext
An OS-agnostic intrusive allocator that uses a programmer-provided buffer to back itself. Useful for when you cannot use your C standard library's allocator, as it also provides some complementary functions for the same.
