import 'dart:ffi';
import 'package:ffi/ffi.dart';

import '../utils/alignment.dart';
import '../exceptions/arena_exception.dart';
import '../arena/arena_stats.dart';

/// A fixed-block-size pool allocator with O(1) alloc **and** O(1) free.
///
/// Unlike [ZeroGcArena] / [BumpAllocator] (which cannot free individual
/// blocks), [ZeroGcPool] supports returning individual slots back to the
/// pool for immediate reuse. This is achieved via an **embedded free-list**:
/// each free slot stores the address of the next free slot in its first
/// 8 bytes (pointer size).
///
/// ## Internal Structure
///
/// ```
/// Native block (capacity × blockSize bytes)
/// ┌────────┬────────┬────────┬────────┬────────┬────────┐
/// │ slot 0 │ slot 1 │ slot 2 │ slot 3 │ slot 4 │ slot 5 │
/// │  FREE  │  USED  │  FREE  │  USED  │  FREE  │  FREE  │
/// └────────┴────────┴────────┴────────┴────────┴────────┘
///     ↓                ↓                ↓         ↓
/// [addr→2]          (data)          [addr→4]  [addr→NULL]
///     ↑
///  _freeHead
/// ```
///
/// Free slots form a singly-linked list. [alloc] pops the head; [free]
/// pushes the slot back. Both operations touch only pointer-sized values —
/// no searching, no sorting, pure O(1).
///
/// ## Best Use Cases
///
/// - **Game entities**: bullets, particles, enemies, projectiles.
/// - **Network connections**: per-connection state blocks.
/// - **Message objects**: fixed-size protocol messages in a server.
/// - **HFT orders**: order objects that are placed and cancelled rapidly.
///
/// ## Usage
///
/// ```dart
/// // 10,000 slots of 64 bytes each (640 KB total)
/// final pool = ZeroGcPool(blockSize: 64, capacity: 10000);
///
/// final slot = pool.alloc();     // O(1), no GC
/// (slot + 0).value = 0xDEAD;    // write raw data
/// pool.free(slot);               // O(1), back to free-list
///
/// pool.dispose();                // free native block
/// ```
///
/// ## Constraints
///
/// - All slots are **exactly** [blockSize] bytes — no variable-size allocs.
/// - [blockSize] must be ≥ 8 bytes (to hold an embedded pointer).
/// - [free] accepts only pointers previously returned by [alloc] on **this**
///   pool. Passing foreign pointers causes silent heap corruption.
class ZeroGcPool {
  // ── Internal state ────────────────────────────────────────────────────────

  late final Pointer<Uint8> _base;

  /// Size of each slot in bytes (aligned up to [AlignmentUtils.defaultAlign]).
  final int blockSize;

  /// Maximum number of slots.
  final int capacity;

  /// Head of the embedded free-list (null when pool is empty).
  int _freeHead = 0; // stored as raw address int for speed

  int _usedSlots = 0;
  late final ArenaStats stats;

  // ── Constructor ───────────────────────────────────────────────────────────

  /// Creates a pool with [capacity] slots of [blockSize] bytes each.
  ///
  /// ## Parameters
  ///
  /// - [blockSize]: Bytes per slot. Automatically rounded up to the next
  ///   multiple of [AlignmentUtils.defaultAlign] (8 bytes) to ensure
  ///   proper alignment for all native types.
  ///   **Minimum**: 8 bytes (pointer width, needed for free-list links).
  /// - [capacity]: Total number of slots to pre-allocate.
  ///
  /// ## Memory usage
  ///
  /// `totalBytes = align8(blockSize) × capacity`
  ///
  /// ```dart
  /// final pool = ZeroGcPool(blockSize: 48, capacity: 50000);
  /// // totalBytes = 48 × 50000 = 2,400,000 bytes ≈ 2.3 MB
  /// ```
  ZeroGcPool({required int blockSize, required int capacity})
      : blockSize = AlignmentUtils.alignUp(
          blockSize.clamp(8, 1 << 30),
          AlignmentUtils.defaultAlignment,
        ),
        capacity = capacity {
    if (blockSize < 8) {
      throw ArgumentError(
        'blockSize must be at least 8 bytes (pointer size for free-list links). '
        'Got $blockSize.',
      );
    }
    if (capacity <= 0) {
      throw ArgumentError.value(capacity, 'capacity', 'Must be positive');
    }

    final totalBytes = this.blockSize * capacity;
    _base = calloc.allocate<Uint8>(totalBytes);
    stats = ArenaStats(totalBytes, label: 'ZeroGcPool');

    _buildFreeList();
  }

  // ── Allocation API ────────────────────────────────────────────────────────

  /// Allocates one [blockSize]-byte slot from the pool. **O(1)**.
  ///
  /// Returns a zero-initialized [Pointer<Uint8>].
  ///
  /// ```dart
  /// final entity = pool.alloc();
  /// writeEntityData(entity);
  /// ```
  ///
  /// Throws [ArenaDisposedException] if the pool has been disposed.
  /// Throws [ArenaOutOfMemoryException] if all [capacity] slots are in use.
  Pointer<Uint8> alloc() {
    _assertLive();
    if (_freeHead == 0) {
      throw ArenaOutOfMemoryException(
        requestedBytes: blockSize,
        availableBytes: 0,
        totalCapacity: blockSize * capacity,
        allocatorType: 'ZeroGcPool',
      );
    }

    // Pop head of free-list
    final slotAddr = _freeHead;
    final nextFree = Pointer<IntPtr>.fromAddress(slotAddr).value;
    _freeHead = nextFree;
    _usedSlots++;

    // Zero out the slot before returning (overwrite free-list link)
    final slotPtr = Pointer<Uint8>.fromAddress(slotAddr);
    for (int i = 0; i < blockSize; i++) {
      (slotPtr + i).value = 0;
    }

    stats.recordAllocation(blockSize);
    return slotPtr;
  }

  /// Returns a slot to the pool. **O(1)**.
  ///
  /// [ptr] **must** be a pointer previously returned by [alloc] on **this**
  /// pool instance. Passing any other pointer causes undefined behavior.
  ///
  /// In debug builds, [_isValidSlot] validates that [ptr] belongs to this
  /// pool's address range and is properly aligned.
  void free(Pointer<Uint8> ptr) {
    _assertLive();
    assert(
      _isValidSlot(ptr),
      'ZeroGcPool.free: pointer 0x${ptr.address.toRadixString(16)} '
      'does not belong to this pool (base=0x${_base.address.toRadixString(16)}, '
      'blockSize=$blockSize, capacity=$capacity).',
    );

    // Push onto free-list head
    Pointer<IntPtr>.fromAddress(ptr.address).value = _freeHead;
    _freeHead = ptr.address;
    _usedSlots--;
    stats.recordFree(blockSize);
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  /// Resets all slots to free state by rebuilding the free-list. **O(n)**.
  ///
  /// Use when you want to release all allocated slots at once while
  /// retaining the pool for reuse (e.g. end of game level).
  void reset() {
    _assertLive();
    stats.recordReset(_usedSlots * blockSize);
    _usedSlots = 0;
    _buildFreeList();
  }

  /// Frees the entire native block. **O(1)**.
  ///
  /// The pool must not be used after [dispose].
  void dispose() {
    _assertLive();
    calloc.free(_base);
    _disposed = true;
    stats.recordDispose();
  }

  // ── Properties ────────────────────────────────────────────────────────────

  /// Number of currently allocated slots.
  int get usedSlots => _usedSlots;

  /// Number of free slots remaining.
  int get freeSlots => capacity - _usedSlots;

  /// `true` when all slots are allocated.
  bool get isFull => _usedSlots >= capacity;

  /// `true` when no slots are allocated.
  bool get isEmpty => _usedSlots == 0;

  /// `true` after [dispose].
  bool get isDisposed => _disposed;

  bool _disposed = false;

  // ── Internal helpers ──────────────────────────────────────────────────────

  void _buildFreeList() {
    // Chain all slots: slot[0] → slot[1] → ... → slot[n-1] → NULL
    for (int i = 0; i < capacity - 1; i++) {
      final slotAddr = _base.address + i * blockSize;
      final nextAddr = _base.address + (i + 1) * blockSize;
      Pointer<IntPtr>.fromAddress(slotAddr).value = nextAddr;
    }
    // Last slot → NULL (0)
    Pointer<IntPtr>.fromAddress(
      _base.address + (capacity - 1) * blockSize,
    ).value = 0;

    _freeHead = _base.address;
  }

  bool _isValidSlot(Pointer<Uint8> ptr) {
    final offset = ptr.address - _base.address;
    return offset >= 0 &&
        offset < blockSize * capacity &&
        offset % blockSize == 0;
  }

  void _assertLive() {
    if (_disposed) throw ArenaDisposedException('ZeroGcPool has been disposed.');
  }

  @override
  String toString() => 'ZeroGcPool('
      'blockSize: $blockSize, '
      'capacity: $capacity, '
      'used: $_usedSlots, '
      'free: $freeSlots)';
}
