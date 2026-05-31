/// Exceptions thrown by zero_gc_allocator when invariants are violated.
///
/// All exceptions carry rich diagnostic context so developers can immediately
/// understand what went wrong and how to fix it, without guesswork.
library;

// ── ArenaOutOfMemoryException ────────────────────────────────────────────────

/// Thrown when an allocator cannot satisfy a memory request.
///
/// This occurs in three scenarios:
///
/// 1. **Arena overflow**: [ZeroGcArena.alloc] requested more bytes than remain.
/// 2. **Pool exhaustion**: [ZeroGcPool.alloc] called when all slots are taken.
/// 3. **Slab exhaustion**: [ZeroGcSlab.alloc] called when all elements are used.
///
/// The exception message includes:
/// - Requested size and available space
/// - Usage bar showing how full the allocator is
/// - A suggested corrective arena size
///
/// ## Example output
///
/// ```
/// ArenaOutOfMemoryException [ZeroGcArena]
///   Requested :      4.00 MB
///   Available :      1.24 MB
///   Used      :    254.76 MB (99.5% of total)
///   Total     :    256.00 MB
///
///   Tip: Create a larger arena with ZeroGcArena(size: 516.mb)
/// ```
class ArenaOutOfMemoryException implements Exception {
  /// Bytes the caller attempted to allocate.
  final int requestedBytes;

  /// Bytes still available in the allocator at the time of failure.
  final int availableBytes;

  /// Total capacity of the allocator (fixed at construction).
  final int totalCapacity;

  /// Textual name of the allocator type for diagnostic messages.
  final String allocatorType;

  const ArenaOutOfMemoryException({
    required this.requestedBytes,
    required this.availableBytes,
    required this.totalCapacity,
    required this.allocatorType,
  });

  int get usedBytes => totalCapacity - availableBytes;

  double get usageRatio =>
      totalCapacity > 0 ? usedBytes / totalCapacity : 0.0;

  @override
  String toString() {
    final usagePct = (usageRatio * 100).toStringAsFixed(1);
    final bar = _buildBar(usageRatio, 28);
    return '''
ArenaOutOfMemoryException [$allocatorType]
  Requested :  ${_fmt(requestedBytes).padLeft(12)}
  Available :  ${_fmt(availableBytes).padLeft(12)}
  Used      :  ${_fmt(usedBytes).padLeft(12)} ($usagePct% of total)
  Total     :  ${_fmt(totalCapacity).padLeft(12)}
  Usage     :  [$bar]

  Tip: Create a larger arena with ZeroGcArena(size: ${_suggestSize(requestedBytes + usedBytes)})
''';
  }

  static String _buildBar(double ratio, int width) {
    final filled = (ratio * width).clamp(0, width).round();
    final empty = width - filled;
    return ('█' * filled) + ('░' * empty);
  }

  static String _fmt(int bytes) {
    if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(2)} GB';
    if (bytes >= 1 << 20) return '${(bytes / (1 << 20)).toStringAsFixed(2)} MB';
    if (bytes >= 1 << 10) return '${(bytes / (1 << 10)).toStringAsFixed(2)} KB';
    return '$bytes B';
  }

  static String _suggestSize(int needed) {
    // Suggest 2× the needed bytes, rounded up to a clean unit.
    final suggested = needed * 2;
    if (suggested >= 1 << 30) return '${((suggested >> 30) + 1)}.gb';
    if (suggested >= 1 << 20) return '${((suggested >> 20) + 1)}.mb';
    if (suggested >= 1 << 10) return '${((suggested >> 10) + 1)}.kb';
    return '${suggested + 1}.bytes';
  }
}

// ── ArenaDisposedException ────────────────────────────────────────────────────

/// Thrown when any operation is attempted on a disposed arena.
///
/// Once [ZeroGcArena.dispose] (or [ZeroGcPool.dispose] / [ZeroGcSlab.dispose])
/// is called, the underlying native block has been freed. Any further
/// [alloc], [reset], [saveCheckpoint] or [restoreCheckpoint] call will throw
/// this exception instead of accessing freed memory.
class ArenaDisposedException implements Exception {
  /// Optional message providing additional context.
  final String message;

  const ArenaDisposedException([
    this.message = 'The arena has been disposed. '
        'Create a new instance or reset before disposing.',
  ]);

  @override
  String toString() => 'ArenaDisposedException: $message';
}

// ── ArenaRegionException ──────────────────────────────────────────────────────

/// Thrown when a region/checkpoint operation violates invariants.
///
/// Possible causes:
/// - Restoring a region that belongs to a **different** arena.
/// - Restoring a region whose saved offset is **ahead** of the current
///   cursor (indicates memory corruption or double-restore).
/// - Restoring an already-restored region.
class ArenaRegionException implements Exception {
  final String message;
  const ArenaRegionException(this.message);

  @override
  String toString() => 'ArenaRegionException: $message';
}
