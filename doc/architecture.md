# Architecture Guide

## Overview

`zero_gc_allocator` is layered into four concerns:

```
┌─────────────────────────────────────────────────────────────┐
│  Public API (zero_gc_allocator.dart)                        │
├──────────────┬──────────────┬──────────────┬───────────────┤
│  Typed       │  Allocators  │  Arena       │  Utils        │
│  native_buffer  bump        │  zero_gc_    │  alignment    │
│  native_list    slab        │  arena       │  memory_guard │
│  typed_ptr      pool        │  arena_stats │               │
└──────────────┴──────────────┴──────────────┴───────────────┘
                         │
               ┌─────────┴────────┐
               │   dart:ffi       │
               │   package:ffi    │
               └──────────────────┘
```

---

## Why Generic FFI Operations Are Restricted

Dart FFI requires that `sizeOf<T>()`, `Pointer<T>.value`, and `Pointer<T> +`
are only called when `T` is a **concrete, compile-time-known** `SizedNativeType`.
Calling them with a generic type parameter (e.g. `T extends NativeType`) is a
compile error.

`zero_gc_allocator` addresses this by:

1. **Using `Pointer<Uint8>` internally** — byte pointers support `elementAt(n)`
   for arbitrary arithmetic.
2. **Exposing concrete typed helpers** — `allocInt32()`, `allocDouble()`, etc.
   call `sizeOf` at the _call site_ where `T` is concrete.
3. **Accepting explicit `elemSize`** — lower-level helpers (`allocElements`,
   `NativeList.withLength`, `SlabAllocator`, …) take `elemSize` as an `int`
   parameter, avoiding generic `sizeOf` entirely.

---

## Allocator Strategies

### BumpAllocator

```
[base ..... cursor ..... capacity]
 ↑ allocated here   ↑ free space
```

- O(1) allocation — just increment the cursor.
- No individual free — call `reset()` to reclaim everything.
- Best for: per-frame scratch buffers, arena sub-regions.

### PoolAllocator / SlabAllocator

```
[slot0][slot1][slot2]...[slotN-1]
  ↑ freeList = [2, 5, 7, ...]
```

- O(1) allocation via free-list stack pop.
- O(1) free via free-list push.
- All slots are the same size.
- Best for: fixed-size objects with unpredictable lifetimes.

### ZeroGcArena

```
 Block 0 [bump cursor ...]
 Block 1 [bump cursor ...]   ← grows here when block 0 full
```

- Internally chains `BumpAllocator` blocks.
- `reset()` reuses all blocks without OS deallocation.
- `dispose()` frees all blocks at once.
- Best for: request-scoped or frame-scoped allocations.

---

## NativeBuffer Design

`NativeBuffer` intentionally avoids `ByteData` for hot paths because converting
between `ByteData` and native memory requires a copy.  For float read/write
where byte reinterpretation is needed, it creates a temporary `ByteData` from
the pointer contents — acceptable for infrequent structured I/O.

---

## TypedPtr<T> Design

`TypedPtr<T>` wraps a `Pointer<Uint8>` and exposes named getters/setters
(`doubleValue`, `int32Value`, etc.) that cast internally to the concrete type.
This pattern allows generic container code to work with `TypedPtr<T>` without
triggering the Dart FFI generic restriction, as long as the concrete casts are
in named property implementations.

---

## Thread Safety

None of the allocators are thread-safe.  If you need concurrent allocation:

- Use **separate allocator instances** per isolate (recommended).
- Or protect shared access with a `Mutex` from `package:mutex`.
