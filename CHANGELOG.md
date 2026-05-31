# Changelog

All notable changes to `zero_gc_allocator` will be documented in this file.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).
Version numbers follow [Semantic Versioning](https://semver.org/).

---

## [1.0.0] — 2026-05-31

### Initial release — Ultra Pro Edition

#### Core allocators

- **`ZeroGcArena`** — Fixed-size bump-pointer arena on the native heap.
  - `alloc(byteCount, {alignment})` — O(1) zero-initialized allocation.
  - `allocUninit(byteCount)` — O(1) uninitialized allocation (faster when caller writes all bytes).
  - `allocTyped<T>(count)` — O(1) type-safe allocation with automatic natural alignment.
  - `saveCheckpoint()` — Saves current cursor as an `ArenaRegion`.
  - `restoreCheckpoint(region)` — O(1) cursor rewind (scoped allocation pattern).
  - `reset({zeroMemory})` — O(1) full reset; optionally zeroes used region.
  - `dispose()` — Frees the native block in one syscall.
  - `remainingBytes`, `usedBytes`, `capacity`, `isEmpty`, `isFull`, `isDisposed`.
  - Integrated `ArenaStats` with `allocationCount`, `peakUsage`, `utilizationRatio`,
    `lifetime`, `snapshot()`, and `delta()` comparison.

- **`ZeroGcPool`** — Fixed-block pool with embedded free-list.
  - `alloc()` — O(1) bump-then-pop from free-list.
  - `free(ptr)` — O(1) push back to free-list head.
  - `reset()` — O(n) rebuild free-list (all slots freed).
  - `dispose()` — O(1) free native block.
  - `blockSize` auto-rounded up to 8-byte alignment.
  - Debug-mode slot validation in `free()` via `assert`.

- **`ZeroGcSlab<T>`** — Type-safe fixed-size pool for a single native type.
  - Typed alloc/free (`Pointer<T>` — no casting).
  - `stride` parameter for multi-element slots (Vec3, Mat4, RGBA, etc.).
  - Same O(1) free-list semantics as `ZeroGcPool`.

- **`BumpAllocator`** — Standalone bump allocator (no checkpoint/region overhead).
  - `allocate(byteCount)` and `allocateTyped<T>(count)`.
  - Identical O(1) / O(1) reset/dispose characteristics.

#### Typed wrappers

- **`TypedPtr<T>`** — Arena-associated type-safe pointer.
  - `fromArena(arena)` — scalar.
  - `arrayFromArena(arena, count: n)` — array with bounds checking.
  - `value` getter/setter for scalar access.
  - `operator [](index)` for array element access.
  - `isAlive` lifecycle check (true while arena is not disposed).

- **`NativeList<T>`** — Bounds-checked typed array.
  - Arena-backed or standalone (`calloc`).
  - `operator [](index)` — bounds-checked element pointer.
  - `subList(start, count)` — zero-copy sub-view.
  - `sizeInBytes`, `basePointer`.
  - `dispose()` — no-op for arena-backed; frees memory for standalone.

- **`NativeString`** — UTF-8 native string with null terminator.
  - `fromDart(String, {arena})`.
  - `concat(List<String>, {arena})` — no intermediate Dart `String`.
  - `fromPointer(Pointer<Uint8>)` — wraps existing C string.
  - `toDartString()`, `byteLength`, `byteAt(index)`, `isEmpty`.
  - `==` and `hashCode` via byte comparison.

- **`NativeBuffer`** — Binary I/O buffer with endian-aware read/write.
  - Random access: `readUint8/16/32/64LE/BE`, `writeUint8/16/32/64LE/BE`.
  - Float support: `readFloat32/64LE`, `writeFloat32/64LE`.
  - Sequential append mode: `appendUint8/16/32/64LE`, `appendBytes`.
  - Bulk: `readBytes`, `writeBytes`, `clear()`.
  - Zero-copy views: `asByteData()`, `asUint8List()`.
  - `writePosition` cursor with `resetWritePosition()`.

#### Extensions

- **`SizeExtension`** — Human-readable size literals on `num`.
  - `.bytes`, `.kb`, `.mb`, `.gb`, `.tb`.
  - `.toSizeString()` — formats bytes as `"X.XX GB"` etc.

- **`Uint8PointerExtensions`** — Ergonomic `Pointer<Uint8>` operations.
  - `fill(count, byte)`, `zeroFill(count)`.
  - `copyFrom(src, count)`, `copyFromList(list)`.
  - `castAt<T>(byteOffset)`.
  - `isAlignedTo(alignment)`.
  - `memEquals(other, count)`.
  - `hexDump(count, {columns})`.
  - `toHexAddress()`.

- **`TypedPointerExtensions<T>`** — Generic pointer helpers.
  - `toHexAddress()`, `isAlignedTo(n)`, `asBytes`, `reinterpretAs<U>()`.
  - `isNull`, `isNotNull`.

#### Exceptions

- **`ArenaOutOfMemoryException`** — Rich diagnostic message with usage bar,
  size breakdown, and suggested corrective arena size.
- **`ArenaDisposedException`** — Thrown on any post-dispose operation.
- **`ArenaRegionException`** — Thrown for invalid checkpoint operations
  (wrong arena, double-restore, corrupted offset).
- **`AlignmentException`** — Thrown for non-power-of-two alignment requests.

#### Utilities

- **`AlignmentUtils`** — Pure-math alignment helpers.
  - `alignUp`, `alignDown`, `isAligned`, `paddingFor`.
  - `isPowerOfTwo`, `nextPowerOfTwo`.
  - `naturalAlignmentForSize`, `alignmentOf<T>`.
  - Constants: `defaultAlign` (8), `simdAlign` (16), `avxAlign` (32),
    `avx512Align` (64), `cacheLineSize` (64), `pageSize` (4096).

- **`PlatformUtils`** — Runtime platform detection.
  - `isWindows`, `isMacOS`, `isIOS`, `isAndroid`, `isLinux`.
  - `isApple`, `isMobile`, `isDesktop`.
  - `is64Bit`, `pointerSize`.
  - `nativeMallocAlignment`, `maxSafeAllocationBytes`.

- **`MemoryGuard`** — Debug-mode buffer overflow detector.
  - Inserts canary regions after each `alloc`.
  - `verify()` — throws `MemoryOverflowDetected` on corruption.
  - `isIntact()` — boolean version of `verify()`.
  - `MemoryOverflowDetected` exception with byte-level diagnostic info.

#### Tests

- `test/arena_test.dart` — 50+ tests for `ZeroGcArena` (construction,
  alloc, typed alloc, uninit alloc, alignment, reset, dispose,
  checkpoints, stats, snapshots).
- `test/pool_allocator_test.dart` — 35+ tests for `ZeroGcPool`,
  `ZeroGcSlab`, and `BumpAllocator`.
- `test/typed_ptr_test.dart` — 60+ tests for `TypedPtr`, `NativeList`,
  `NativeString`, `NativeBuffer`, pointer extensions, size extensions,
  and `AlignmentUtils`.
- `test/memory_safety_test.dart` — Safety invariant tests: `MemoryGuard`
  overflow detection, dispose-then-use invariants, bounds checking.
- `test/concurrent_test.dart` — Isolate independence tests, pointer
  address communication across isolates, stress tests.

#### Benchmarks

- `benchmark/arena_vs_dart_benchmark.dart` — `benchmark_harness`-based
  comparison of GC vs arena for bulk allocation.
- `benchmark/alloc_throughput_benchmark.dart` — Raw allocs/second for
  all allocator types.
- `benchmark/gc_pause_comparison.dart` — Frame consistency simulation
  showing jank rate difference at 120 fps.

#### Examples

- `example/basic_usage.dart` — Full API tour.
- `example/game_frame_arena.dart` — 3,600-frame game loop simulation
  with persistent/frame arenas and particle pool.
- `example/hft_order_book.dart` — 100K order place/cancel/fill
  benchmark with binary protocol encoding.
- `example/websocket_server.dart` — 10K concurrent connection simulation
  with per-connection pool-allocated I/O buffers.

---

## Future Roadmap

### [1.1.0] — Planned

- `ZeroGcRingBuffer` — Lock-free single-producer/single-consumer ring buffer
  for inter-isolate communication without GC.
- `ZeroGcStack<T>` — LIFO typed stack on native heap.
- `ZeroGcHashMap<K, V>` — Open-addressing hash map on native heap.
- `NativeBuffer` big-endian float methods.
- WASM support investigation (behind a compile-time flag).

### [1.2.0] — Planned

- `ArenaGroup` — Multiple arenas managed as a single logical allocator
  (auto-overflow to next arena).
- Arena serialization to/from `R2Bucket` / file for crash dumps.
- Optional `Finalizer`-based safety net (debug mode only).
- Flutter plugin for pre-allocating arenas at app startup.
