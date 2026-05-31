import 'dart:ffi';
import 'package:ffi/ffi.dart';

import '../utils/alignment.dart';
import '../exceptions/arena_exception.dart';
import '../arena/arena_stats.dart';

/// A standalone bump-pointer allocator that owns its native memory block.
///
/// [BumpAllocator] is the low-level engine behind [ZeroGcArena]. It can
/// also be used directly when you want a self-contained allocator without
/// the full arena feature set (no checkpoints, no typed-alloc sugar).
///
/// ## Algorithm
///
/// A bump allocator maintains a single cursor (`_cursor`) into a contiguous
/// buffer. Each allocation advances the cursor by the requested size plus any
/// alignment padding. Freeing individual allocations is not possible — the
/// entire block is reset at once.
///
/// ```
/// ┌─────┬─────┬─────┬─────────────────────────────────────┐
/// │  A  │  B  │  C  │               FREE                  │
/// └─────┴─────┴─────┴─────────────────────────────────────┘
///                     ↑
///                  cursor
///
/// After reset():
/// ┌─────────────────────────────────────────────────────────┐
/// │                         FREE                            │
/// └─────────────────────────────────────────────────────────┘
/// ↑
/// cursor = 0
/// ```
///
/// ## When to Use
///
/// Prefer [ZeroGcArena] for most use cases — it wraps this allocator and
/// adds the typed API, checkpoint/region support, and richer stats.
/// Use [BumpAllocator] directly when embedding into a lower-level system
/// where the full arena overhead is undesirable.
///
/// ## Performance
///
/// | Operation | Time complexity | Typical wall time |
/// |-----------|-----------------|-------------------|
/// | alloc()   | O(1)            | 2–4 ns            |
/// | reset()   | O(1)            | <1 ns             |
/// | dispose() | O(1)            | ~10 ns (syscall)  |
class BumpAllocator {
  // ── Internal state ────────────────────────────────────────────────────────

  late final Pointer<Uint8> _buffer;
  final int capacity;
  int _cursor = 0;
  bool _disposed = false;
  late final ArenaStats stats;

  // ── Constructor ───────────────────────────────────────────────────────────

  /// Creates a [BumpAllocator] with [capacity] bytes of zero-initialized
  /// native memory.
  ///
  /// ```dart
  /// final alloc = BumpAllocator(capacity: 4.mb);
  /// ```
  ///
  /// Throws [ArgumentError] if [capacity] ≤ 0.
  BumpAllocator({required this.capacity}) {
    if (capacity <= 0) {
      throw ArgumentError.value(capacity, 'capacity', 'Must be positive');
    }
    _buffer = calloc.allocate<Uint8>(capacity);
    stats = ArenaStats(capacity, label: 'BumpAllocator');
  }

  // ── Allocation API ────────────────────────────────────────────────────────

  /// Allocates [byteCount] zero-initialized bytes. O(1).
  ///
  /// ```dart
  /// final ptr = alloc.allocate(256);
  /// ptr.value = 42;
  /// ```
  Pointer<Uint8> allocate(
    int byteCount, {
    int alignment = AlignmentUtils.defaultAlignment,
  }) {
    _assertLive();
    if (byteCount <= 0) {
      throw ArgumentError.value(byteCount, 'byteCount', 'Must be positive');
    }

    final alignedCursor = AlignmentUtils.alignUp(_cursor, alignment);
    final end = alignedCursor + byteCount;

    if (end > capacity) {
      throw ArenaOutOfMemoryException(
        requestedBytes: byteCount,
        availableBytes: capacity - _cursor,
        totalCapacity: capacity,
        allocatorType: 'BumpAllocator',
      );
    }

    final ptr = Pointer<Uint8>.fromAddress(_buffer.address + alignedCursor);
    _cursor = end;
    stats.recordAllocation(end - (alignedCursor - byteCount).abs());
    return ptr;
  }

  /// Allocates [count] elements of native type [T].
  ///
  /// [elemSize] **must** be `sizeOf<T>()` evaluated at the concrete call site,
  /// because Dart's FFI `sizeOf` cannot accept generic type parameters.
  ///
  /// ```dart
  /// final ints = alloc.allocateTyped<Int32>(512, elemSize: sizeOf<Int32>());
  /// Pointer<Int32>.fromAddress(ints.address).value = 100;
  /// ```
  Pointer<T> allocateTyped<T extends SizedNativeType>(
    int count, {
    required int elemSize,
  }) {
    final alignment = AlignmentUtils.naturalAlignmentForSize(elemSize);
    return allocate(elemSize * count, alignment: alignment).cast<T>();
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  /// Resets the cursor to zero. O(1).
  ///
  /// Existing [Pointer] values become stale after this call.
  void reset() {
    _assertLive();
    stats.recordReset(_cursor);
    _cursor = 0;
  }

  /// Releases the native buffer. O(1).
  void dispose() {
    _assertLive();
    calloc.free(_buffer);
    _disposed = true;
    stats.recordDispose();
  }

  // ── Properties ────────────────────────────────────────────────────────────

  /// Bytes consumed so far (cursor position).
  int get usedBytes => _cursor;

  /// Bytes available for future allocations.
  int get remainingBytes => capacity - _cursor;

  /// `true` after [dispose].
  bool get isDisposed => _disposed;

  /// `true` when cursor is at zero.
  bool get isEmpty => _cursor == 0;

  /// `true` when no bytes remain.
  bool get isFull => _cursor >= capacity;

  void _assertLive() {
    if (_disposed) throw ArenaDisposedException('BumpAllocator has been disposed.');
  }

  @override
  String toString() =>
      'BumpAllocator(capacity: $capacity, used: $_cursor, free: $remainingBytes)';
}
