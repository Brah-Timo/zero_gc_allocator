import 'dart:ffi';
import 'package:ffi/ffi.dart';

import '../utils/alignment.dart';
import '../exceptions/arena_exception.dart';
import '../arena/arena_stats.dart';

/// A type-safe, fixed-size pool allocator specialized for a single native type.
///
/// [ZeroGcSlab<T>] is conceptually identical to [ZeroGcPool] but typed:
/// each slot holds exactly [stride] elements of native type [T], and alloc/free
/// return [Pointer<T>] instead of [Pointer<Uint8>] — no casting required.
///
/// ## Design Rationale
///
/// Named after the **slab allocator** concept introduced by Jeff Bonwick (Sun
/// Microsystems, 1994). The original slab allocator pre-allocates and
/// pre-constructs objects of the same type, reusing them to avoid both
/// allocation overhead and construction overhead.
///
/// In our case, "construction" is simply zeroing: each slot is zero-initialized
/// on first allocation and on each [free]-then-[alloc] cycle.
///
/// ## Memory Layout
///
/// ```
/// ZeroGcSlab<Float>(elementCount: 4, stride: 3)
/// Slot size = sizeOf<Float>() × 3 = 4 × 3 = 12 bytes
///
/// ┌──────────────┬──────────────┬──────────────┬──────────────┐
/// │  slot 0      │  slot 1      │  slot 2      │  slot 3      │
/// │ [f f f]12B   │ [f f f]12B   │ [f f f]12B   │ [f f f]12B   │
/// └──────────────┴──────────────┴──────────────┴──────────────┘
///   ptr[0] ptr[1]  ptr[2]         (FREE)          (FREE)
/// ```
///
/// ## Usage — Vec3 pool
///
/// ```dart
/// // Pool of 50,000 Vec3 = 50,000 × (3 × 4 bytes) = 600 KB
/// final vec3Pool = ZeroGcSlab<Float>(elementCount: 50000, stride: 3);
///
/// // Allocate a Vec3 slot — returns Pointer<Float> to 3 floats
/// final v = vec3Pool.alloc();
/// v[0] = 1.0; // x
/// v[1] = 0.0; // y
/// v[2] = 0.0; // z
///
/// // Process and return to pool
/// vec3Pool.free(v);
/// ```
///
/// ## Usage — Matrix 4×4 pool
///
/// ```dart
/// // Pool of 1,000 Mat4 = 1,000 × (16 × 4 bytes) = 64 KB
/// final matPool = ZeroGcSlab<Float>(elementCount: 1000, stride: 16);
///
/// final mat = matPool.alloc(); // Pointer<Float> to 16 floats
/// mat[0]  = 1.0; mat[5]  = 1.0; mat[10] = 1.0; mat[15] = 1.0; // identity
///
/// matPool.free(mat);
/// ```
///
/// ## Constraints
///
/// - Slot size (`sizeOf<T>() * stride`) must be ≥ 8 bytes.
/// - Only pointers returned by **this** slab may be passed to [free].
class ZeroGcSlab<T extends SizedNativeType> {
  // ── Internal state ────────────────────────────────────────────────────────

  late final Pointer<Uint8> _base;

  /// Number of T elements per slot.
  final int stride;

  /// Maximum number of slots.
  final int elementCount;

  /// Bytes per slot.
  late final int _slotBytes;

  int _freeHead = 0;
  int _usedSlots = 0;
  bool _disposed = false;
  late final ArenaStats stats;

  // ── Constructor ───────────────────────────────────────────────────────────

  /// Creates a slab of [elementCount] slots, each holding [stride] values
  /// of type [T].
  ///
  /// ```dart
  /// // 10,000 slots of Int64 (8 bytes each) = 80 KB
  /// final ids = ZeroGcSlab<Int64>(elementCount: 10000, stride: 1);
  ///
  /// // 5,000 slots of Double × 4 (RGBA color) = 160 KB
  /// final colors = ZeroGcSlab<Double>(elementCount: 5000, stride: 4);
  /// ```
  /// [elemSize] **must** be `sizeOf<T>()` evaluated at the concrete call site,
  /// because Dart's FFI `sizeOf` cannot accept generic type parameters.
  ///
  /// ```dart
  /// final vec3Pool = ZeroGcSlab<Float>(
  ///     elementCount: 50000, stride: 3, elemSize: sizeOf<Float>());
  /// ```
  ZeroGcSlab({required this.elementCount, this.stride = 1, required int elemSize}) {
    if (elementCount <= 0) {
      throw ArgumentError.value(elementCount, 'elementCount', 'Must be positive');
    }
    if (stride <= 0) {
      throw ArgumentError.value(stride, 'stride', 'Must be positive');
    }
    if (elemSize <= 0) {
      throw ArgumentError.value(elemSize, 'elemSize', 'Must be positive');
    }

    final rawSlotBytes = elemSize * stride;

    // Slot must be at least pointer-width for embedded free-list
    if (rawSlotBytes < 8) {
      throw ArgumentError(
        'Slab slot size ($elemSize × $stride = $rawSlotBytes bytes) must be '
        '≥ 8 bytes to accommodate an embedded free-list pointer. '
        'Increase stride or choose a larger type T.',
      );
    }

    _slotBytes = AlignmentUtils.alignUp(
      rawSlotBytes,
      AlignmentUtils.naturalAlignmentForSize(elemSize),
    );

    final totalBytes = _slotBytes * elementCount;
    _base = calloc.allocate<Uint8>(totalBytes);
    stats = ArenaStats(totalBytes, label: 'ZeroGcSlab<$T>');

    _buildFreeList();
  }

  // ── Allocation API ────────────────────────────────────────────────────────

  /// Allocates one slot from the slab. **O(1)**.
  ///
  /// Returns a [Pointer<T>] pointing to [stride] contiguous elements.
  ///
  /// ```dart
  /// final color = colorSlab.alloc();
  /// color[0] = 1.0; // R
  /// color[1] = 0.5; // G
  /// color[2] = 0.0; // B
  /// color[3] = 1.0; // A
  /// ```
  ///
  /// Throws [ArenaOutOfMemoryException] when all slots are in use.
  Pointer<T> alloc() {
    _assertLive();
    if (_freeHead == 0) {
      throw ArenaOutOfMemoryException(
        requestedBytes: _slotBytes,
        availableBytes: 0,
        totalCapacity: _slotBytes * elementCount,
        allocatorType: 'ZeroGcSlab<$T>',
      );
    }

    final slotAddr = _freeHead;
    _freeHead = Pointer<IntPtr>.fromAddress(slotAddr).value;
    _usedSlots++;

    // Zero the slot
    final slotPtr = Pointer<Uint8>.fromAddress(slotAddr);
    for (int i = 0; i < _slotBytes; i++) {
      (slotPtr + i).value = 0;
    }

    stats.recordAllocation(_slotBytes);
    return Pointer<T>.fromAddress(slotAddr);
  }

  /// Returns a slot to the slab. **O(1)**.
  ///
  /// [ptr] must be a pointer returned by [alloc] on **this** slab instance.
  void free(Pointer<T> ptr) {
    _assertLive();
    assert(
      _isValidSlot(ptr.cast<Uint8>()),
      'ZeroGcSlab.free: pointer 0x${ptr.address.toRadixString(16)} '
      'does not belong to this slab.',
    );
    Pointer<IntPtr>.fromAddress(ptr.address).value = _freeHead;
    _freeHead = ptr.address;
    _usedSlots--;
    stats.recordFree(_slotBytes);
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  /// Rebuilds the free-list, effectively marking all slots as free. **O(n)**.
  void reset() {
    _assertLive();
    stats.recordReset(_usedSlots * _slotBytes);
    _usedSlots = 0;
    _buildFreeList();
  }

  /// Frees the entire native block. **O(1)**.
  void dispose() {
    _assertLive();
    calloc.free(_base);
    _disposed = true;
    stats.recordDispose();
  }

  // ── Properties ────────────────────────────────────────────────────────────

  /// Bytes per slot (includes alignment padding).
  int get slotBytes => _slotBytes;

  /// Number of currently allocated slots.
  int get usedSlots => _usedSlots;

  /// Number of free slots remaining.
  int get freeSlots => elementCount - _usedSlots;

  /// `true` when all slots are allocated.
  bool get isFull => _usedSlots >= elementCount;

  /// `true` when no slots are allocated.
  bool get isEmpty => _usedSlots == 0;

  bool get isDisposed => _disposed;

  // ── Internal helpers ──────────────────────────────────────────────────────

  void _buildFreeList() {
    for (int i = 0; i < elementCount - 1; i++) {
      final cur = _base.address + i * _slotBytes;
      final next = _base.address + (i + 1) * _slotBytes;
      Pointer<IntPtr>.fromAddress(cur).value = next;
    }
    Pointer<IntPtr>.fromAddress(
      _base.address + (elementCount - 1) * _slotBytes,
    ).value = 0;
    _freeHead = _base.address;
  }

  bool _isValidSlot(Pointer<Uint8> ptr) {
    final offset = ptr.address - _base.address;
    return offset >= 0 &&
        offset < _slotBytes * elementCount &&
        offset % _slotBytes == 0;
  }

  void _assertLive() {
    if (_disposed) throw ArenaDisposedException('ZeroGcSlab has been disposed.');
  }

  @override
  String toString() => 'ZeroGcSlab<$T>('
      'stride: $stride, '
      'slotBytes: $_slotBytes, '
      'capacity: $elementCount, '
      'used: $_usedSlots, '
      'free: $freeSlots)';
}
