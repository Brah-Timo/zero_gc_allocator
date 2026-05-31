import 'dart:ffi';
import 'package:ffi/ffi.dart';

import '../utils/alignment.dart';
import '../exceptions/arena_exception.dart';
import 'arena_stats.dart';
import 'arena_region.dart';

/// A fixed-size memory arena that allocates entirely on the native heap,
/// bypassing Dart's Garbage Collector.
///
/// ## Philosophy
///
/// Dart's GC is excellent for general-purpose code but imposes
/// **"Stop-The-World" (STW) pauses** of 0.5 ms–50 ms whenever it needs
/// to reclaim heap objects. For latency-sensitive code — game loops targeting
/// 120 fps (8.3 ms budget), HFT order books (<1 μs target), or WebSocket
/// servers handling millions of concurrent messages — these pauses are
/// unacceptable.
///
/// [ZeroGcArena] solves this by:
///
/// 1. **One big allocation at startup** via `calloc.allocate` → the OS
///    hands us a contiguous native block. The GC never sees it.
/// 2. **Bump-pointer allocation** for every `alloc` call → just an integer
///    increment. O(1), deterministic, cache-friendly.
/// 3. **O(1) reset** → rewinding the cursor to 0 "frees" all allocations
///    simultaneously, without touching individual objects.
///
/// ## Memory Layout
///
/// ```
/// Base address
///  │
///  ▼
/// ┌────────────────────────────────────────────────────────────────┐
/// │               Native Heap Block (e.g. 1 GB)                   │
/// ├──────────┬──────────┬──────────┬────────────────────────────── ┤
/// │ alloc #1 │ alloc #2 │ alloc #3 │           FREE                │
/// │  (128 B) │  (64 B)  │ (4096 B) │                               │
/// └──────────┴──────────┴──────────┴───────────────────────────────┘
///                                   ↑
///                               _offset (cursor)
/// ```
///
/// ## Typical Lifecycle
///
/// ```dart
/// // 1. Create once (expensive: syscall)
/// final arena = ZeroGcArena(size: 1.gb);
///
/// // 2. Allocate as needed (cheap: integer add)
/// final header  = arena.alloc(128);
/// final payload = arena.allocTyped<Float>(1024);
///
/// // 3. Use scoped regions for temporary data
/// final frame = arena.saveCheckpoint();
/// final temp  = arena.alloc(4096);
/// arena.restoreCheckpoint(frame); // O(1) scope exit
///
/// // 4. Reset to reuse the entire block (game-loop style)
/// arena.reset();
///
/// // 5. Dispose when truly done
/// arena.dispose();
/// ```
///
/// ## Thread / Isolate Safety
///
/// [ZeroGcArena] is **not thread-safe**. Use one arena per [Isolate].
/// You may pass raw [Pointer] addresses (as `int`) between isolates via
/// [SendPort] — native pointers are valid across Dart isolate boundaries
/// because they live outside the Dart heap.
///
/// ## Performance Characteristics
///
/// | Operation            | Time   | Notes                            |
/// |----------------------|--------|----------------------------------|
/// | alloc(n)             | O(1)   | 2–5 ns on modern hardware        |
/// | allocTyped<T>(n)     | O(1)   | identical to alloc + cast        |
/// | allocUninit(n)       | O(1)   | skips zero-init, slightly faster |
/// | saveCheckpoint()     | O(1)   | stores one integer               |
/// | restoreCheckpoint()  | O(1)   | restores one integer             |
/// | reset()              | O(1)   | _offset = 0                      |
/// | dispose()            | O(1)   | single calloc.free call          |
class ZeroGcArena {
  // ── Internal state ────────────────────────────────────────────────────────

  /// Base pointer to the start of the native block.
  late final Pointer<Uint8> _base;

  /// Total capacity in bytes (immutable after construction).
  final int _capacity;

  /// Allocation cursor — bytes consumed so far (including alignment padding).
  int _offset = 0;

  /// Whether [dispose] has been called.
  bool _disposed = false;

  /// Memory usage statistics (lightweight, always active).
  late final ArenaStats stats;

  // ── Constructor ───────────────────────────────────────────────────────────

  /// Creates a new arena with [size] bytes of zero-initialized native memory.
  ///
  /// ## Parameters
  ///
  /// - [size]: Total bytes to reserve. Use [SizeExtension] for readability:
  ///   `1.gb`, `512.mb`, `64.kb`.
  /// - [alignment]: Base address alignment (default: 8 bytes). Pass 16 for
  ///   SIMD-safe base addresses, 64 for cache-line-aligned arenas.
  ///
  /// ## Throws
  ///
  /// - [ArgumentError] if [size] ≤ 0.
  /// - Platform `OutOfMemoryError` if the OS cannot satisfy the request.
  ///
  /// ## Example
  ///
  /// ```dart
  /// final frameArena    = ZeroGcArena(size: 64.mb);
  /// final persistentArena = ZeroGcArena(size: 1.gb);
  /// final simdArena     = ZeroGcArena(size: 32.mb, alignment: 16);
  /// ```
  ZeroGcArena({
    required int size,
    int alignment = AlignmentUtils.defaultAlignment,
  }) : _capacity = size {
    if (size <= 0) {
      throw ArgumentError.value(size, 'size', 'Must be a positive byte count');
    }
    _base = calloc.allocate<Uint8>(size);
    stats = ArenaStats(size);
  }

  // ── Core allocation API ───────────────────────────────────────────────────

  /// Allocates [byteCount] bytes from the arena (zero-initialized).
  ///
  /// Returns a [Pointer<Uint8>] to the allocated region.
  /// The pointer is valid until the next [reset] or [dispose] call.
  ///
  /// **O(1)** — this is a single integer add plus an alignment round-up.
  ///
  /// ```dart
  /// final buf = arena.alloc(1024);
  /// buf.value = 0xFF; // write first byte
  /// ```
  ///
  /// ## Parameters
  ///
  /// - [byteCount]: Number of bytes to allocate. Must be > 0.
  /// - [alignment]: Byte alignment (default: 8). Must be a power of two.
  ///
  /// ## Throws
  ///
  /// - [ArgumentError] if [byteCount] ≤ 0.
  /// - [ArenaDisposedException] if the arena has been disposed.
  /// - [ArenaOutOfMemoryException] if insufficient space remains.
  Pointer<Uint8> alloc(
    int byteCount, {
    int alignment = AlignmentUtils.defaultAlignment,
  }) {
    _assertNotDisposed();
    _assertPositive(byteCount, 'byteCount');
    _validateAlignment(alignment);

    final alignedOffset = AlignmentUtils.alignUp(_offset, alignment);
    final endOffset = alignedOffset + byteCount;

    _checkCapacity(byteCount, alignedOffset, endOffset);

    final ptr = Pointer<Uint8>.fromAddress(_base.address + alignedOffset);
    final totalConsumed = endOffset - _offset;
    _offset = endOffset;
    stats.recordAllocation(totalConsumed);

    return ptr;
  }

  /// Allocates [byteCount] bytes **without** zero-initialization.
  ///
  /// Slightly faster than [alloc] because it skips the implicit `memset`.
  /// Use only when you will **immediately overwrite every byte**.
  ///
  /// ```dart
  /// final buf = arena.allocUninit(sizeof<Matrix4x4>());
  /// // Immediately write all 64 bytes before reading any
  /// writeMatrix(buf, myMatrix);
  /// ```
  Pointer<Uint8> allocUninit(
    int byteCount, {
    int alignment = AlignmentUtils.defaultAlignment,
  }) {
    _assertNotDisposed();
    _assertPositive(byteCount, 'byteCount');
    _validateAlignment(alignment);

    final alignedOffset = AlignmentUtils.alignUp(_offset, alignment);
    final endOffset = alignedOffset + byteCount;

    _checkCapacity(byteCount, alignedOffset, endOffset);

    final ptr = Pointer<Uint8>.fromAddress(_base.address + alignedOffset);
    _offset = endOffset;
    stats.recordAllocation(byteCount);
    return ptr;
  }

  /// Allocates space for [count] elements of native type [T].
  ///
  /// This is the primary typed allocation API. The returned pointer supports
  /// direct element access via `Pointer<T>.fromAddress(ptr.address + i * elemSize)`.
  ///
  /// [elemSize] **must** be `sizeOf<T>()` evaluated at the concrete call site,
  /// because Dart's FFI `sizeOf` cannot accept generic type parameters at runtime.
  ///
  /// ```dart
  /// // Allocate 1 million Float32 values (4 MB)
  /// final prices = arena.allocTyped<Float>(1000000, elemSize: sizeOf<Float>());
  ///
  /// // Allocate 64 4×4 transformation matrices (64 × 64 bytes = 4 KB)
  /// final matrices = arena.allocTyped<Float>(64 * 16, elemSize: sizeOf<Float>());
  /// ```
  ///
  /// The alignment defaults to `naturalAlignmentForSize(elemSize)`,
  /// ensuring correct alignment for all standard native types.
  Pointer<T> allocTyped<T extends SizedNativeType>(
    int count, {
    required int elemSize,
    int? alignment,
  }) {
    final align = alignment ?? AlignmentUtils.naturalAlignmentForSize(elemSize);
    final ptr = alloc(elemSize * count, alignment: align);
    return ptr.cast<T>();
  }

  // ── Checkpoint / Region API ───────────────────────────────────────────────

  /// Saves the current allocation cursor as a named region.
  ///
  /// Call [restoreCheckpoint] later to rewind the cursor to this position,
  /// effectively freeing all allocations made in between.
  ///
  /// ```dart
  /// void processRequest(ZeroGcArena arena, Request req) {
  ///   final scope = arena.saveCheckpoint();
  ///
  ///   // These allocations live only for this request
  ///   final headers = arena.alloc(req.headerSize);
  ///   final body    = arena.alloc(req.bodySize);
  ///   processWithBuffers(headers, body);
  ///
  ///   arena.restoreCheckpoint(scope); // O(1) cleanup
  /// }
  /// ```
  ///
  /// Regions may be nested arbitrarily. Restore in **reverse** order.
  ArenaRegion saveCheckpoint() {
    _assertNotDisposed();
    return ArenaRegion(arena: this, offsetAtCreation: _offset);
  }

  /// Restores the arena cursor to the state captured in [region].
  ///
  /// All allocations made after [region] was created are considered freed.
  /// The underlying memory is still present but the cursor is rewound over it —
  /// future allocations will overwrite it.
  ///
  /// ## Throws
  ///
  /// - [ArenaDisposedException] if the arena has been disposed.
  /// - [ArenaRegionException] if [region] belongs to a different arena.
  /// - [ArenaRegionException] if [region] has already been restored.
  /// - [ArenaRegionException] if region's offset is ahead of the cursor
  ///   (indicates double-restore or memory corruption).
  void restoreCheckpoint(ArenaRegion region) {
    _assertNotDisposed();

    if (region.arena != this) {
      throw ArenaRegionException(
        'Region (offset=${region.offsetAtCreation}) was created by a different '
        'arena. Cannot restore across arena boundaries.',
      );
    }
    if (region.isRestored) {
      throw ArenaRegionException(
        'Region at offset ${region.offsetAtCreation} has already been restored. '
        'Double-restore is a logic error in the caller.',
      );
    }
    if (region.offsetAtCreation > _offset) {
      throw ArenaRegionException(
        'Region offset (${region.offsetAtCreation}) is ahead of current cursor '
        '($_offset). This indicates memory corruption or an out-of-order restore.',
      );
    }

    final freed = _offset - region.offsetAtCreation;
    _offset = region.offsetAtCreation;
    stats.recordReset(freed);
    region.markRestored();
  }

  // ── Reset / Dispose ───────────────────────────────────────────────────────

  /// Rewinds the allocation cursor to zero.
  ///
  /// **Does not** free the native block. The same block is reused from the
  /// beginning. All previously obtained [Pointer] values become stale —
  /// do not use them after [reset].
  ///
  /// **O(1)** — sets `_offset = 0`.
  ///
  /// ## Parameters
  ///
  /// - [zeroMemory]: If `true`, the used portion of the block is zeroed
  ///   before resetting the cursor. Useful for security-sensitive scenarios.
  ///   Default: `false` (leave old bytes in place — slightly faster).
  ///
  /// ## Example (game loop)
  ///
  /// ```dart
  /// while (running) {
  ///   processInput(arena);
  ///   updatePhysics(arena);
  ///   renderFrame(arena);
  ///   arena.reset(); // All frame allocations gone in one call
  /// }
  /// ```
  void reset({bool zeroMemory = false}) {
    _assertNotDisposed();
    if (zeroMemory && _offset > 0) {
      // Zero out exactly the used region (not the entire block).
      for (int i = 0; i < _offset; i++) {
        (_base + i).value = 0;
      }
    }
    stats.recordReset(_offset);
    _offset = 0;
  }

  /// Frees the entire native block and marks this arena as disposed.
  ///
  /// After calling [dispose], any further use of this arena throws
  /// [ArenaDisposedException]. All [Pointer] values obtained from this
  /// arena become dangling — accessing them is undefined behavior.
  void dispose() {
    _assertNotDisposed();
    calloc.free(_base);
    _disposed = true;
    stats.recordDispose();
  }

  // ── Properties ────────────────────────────────────────────────────────────

  /// Remaining bytes available for allocation.
  int get remainingBytes => _capacity - _offset;

  /// Bytes consumed (cursor position + padding waste).
  int get usedBytes => _offset;

  /// Total capacity as specified at construction.
  int get capacity => _capacity;

  /// `true` after [dispose] has been called.
  bool get isDisposed => _disposed;

  /// `true` when the cursor is at position 0 (no allocations or after reset).
  bool get isEmpty => _offset == 0;

  /// `true` when no bytes remain for allocation.
  bool get isFull => _offset >= _capacity;

  /// The raw base address of the native block.
  ///
  /// Exposed for advanced use cases (e.g. passing the arena base to native
  /// code via FFI). Do not store beyond the arena's lifetime.
  int get baseAddress => _base.address;

  // ── Internal helpers ──────────────────────────────────────────────────────

  void _assertNotDisposed() {
    if (_disposed) {
      throw ArenaDisposedException(
        'ZeroGcArena has been disposed. '
        'Create a new instance or do not call dispose prematurely.',
      );
    }
  }

  static void _assertPositive(int value, String name) {
    if (value <= 0) {
      throw ArgumentError.value(value, name, 'Must be a positive integer');
    }
  }

  static void _validateAlignment(int alignment) {
    if (!AlignmentUtils.isPowerOfTwo(alignment)) {
      throw ArgumentError.value(
        alignment,
        'alignment',
        'Must be a power of two (e.g. 1, 2, 4, 8, 16, 32, 64)',
      );
    }
  }

  void _checkCapacity(int requested, int alignedOffset, int endOffset) {
    if (endOffset > _capacity) {
      throw ArenaOutOfMemoryException(
        requestedBytes: requested,
        availableBytes: _capacity - _offset,
        totalCapacity: _capacity,
        allocatorType: 'ZeroGcArena',
      );
    }
  }

  @override
  String toString() => 'ZeroGcArena('
      'capacity: ${stats.totalCapacity}, '
      'used: $_offset, '
      'free: $remainingBytes, '
      'disposed: $_disposed)';
}
