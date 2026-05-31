/// Real-time memory usage statistics for any zero_gc_allocator allocator.
///
/// [ArenaStats] is embedded in every allocator and updated on every
/// [alloc], [reset], and [dispose] call. Overhead is a single integer
/// increment — effectively zero.
///
/// ## Usage
///
/// ```dart
/// final arena = ZeroGcArena(size: 256.mb);
/// arena.alloc(64.kb);
/// arena.alloc(128.kb);
///
/// print(arena.stats);
/// // ╔══════════════════════════════════════════╗
/// // ║         ZeroGcArena Memory Stats         ║
/// // ╠══════════════════════════════════════════╣
/// // ║ Total Capacity :      256.00 MB          ║
/// // ║ Used           :      192.00 KB (0.07%)  ║
/// // ║ Free           :      255.81 MB          ║
/// // ║ Peak Usage     :      192.00 KB          ║
/// // ║ Allocations    :             2           ║
/// // ...
/// ```
class ArenaStats {
  // ── Immutable fields ──────────────────────────────────────────────────────

  /// Total bytes reserved on the native heap at construction time.
  final int totalCapacity;

  /// Identifier string shown in [toString] output.
  final String label;

  // ── Mutable counters (updated by allocator internals) ─────────────────────

  int _usedBytes = 0;
  int _allocationCount = 0;
  int _freeCount = 0;
  int _resetCount = 0;
  int _peakUsage = 0;
  final DateTime _createdAt;

  ArenaStats(this.totalCapacity, {this.label = 'ZeroGcArena'})
      : _createdAt = DateTime.now();

  // ── Read-only accessors ────────────────────────────────────────────────────

  /// Bytes currently considered "allocated" (cursor position in arena).
  int get usedBytes => _usedBytes;

  /// Bytes not yet claimed by any allocation.
  int get freeBytes => totalCapacity - _usedBytes;

  /// Total number of successful [alloc] / [allocTyped] calls.
  int get allocationCount => _allocationCount;

  /// Total number of [free] calls (pool/slab only).
  int get freeCount => _freeCount;

  /// Number of times [reset] was called on this allocator.
  int get resetCount => _resetCount;

  /// Highest [usedBytes] ever reached (useful for right-sizing arenas).
  int get peakUsage => _peakUsage;

  /// Ratio of used to total bytes, in [0.0, 1.0].
  double get utilizationRatio =>
      totalCapacity > 0 ? _usedBytes / totalCapacity : 0.0;

  /// Usage as a human-readable percentage string (e.g. `"73.42%"`).
  String get utilizationPercent =>
      '${(utilizationRatio * 100).toStringAsFixed(2)}%';

  /// How long this allocator has been alive.
  Duration get lifetime => DateTime.now().difference(_createdAt);

  // ── Internal mutation methods (called by allocators) ──────────────────────

  /// Records a successful allocation of [bytes] bytes.
  void recordAllocation(int bytes) {
    _usedBytes += bytes;
    _allocationCount++;
    if (_usedBytes > _peakUsage) _peakUsage = _usedBytes;
  }

  /// Records a [free] of [bytes] bytes back to the pool/slab free-list.
  void recordFree(int bytes) {
    _usedBytes = (_usedBytes - bytes).clamp(0, totalCapacity);
    _freeCount++;
  }

  /// Records a full or partial reset, clearing [freedBytes].
  void recordReset(int freedBytes) {
    _usedBytes = (_usedBytes - freedBytes).clamp(0, totalCapacity);
    _resetCount++;
  }

  /// Resets all counters to zero (called on dispose).
  void recordDispose() {
    _usedBytes = 0;
  }

  // ── Snapshot ───────────────────────────────────────────────────────────────

  /// Returns an immutable snapshot of current stats.
  ArenaSnapshot snapshot() => ArenaSnapshot(
        totalCapacity: totalCapacity,
        usedBytes: _usedBytes,
        freeBytes: freeBytes,
        peakUsage: _peakUsage,
        allocationCount: _allocationCount,
        freeCount: _freeCount,
        resetCount: _resetCount,
        lifetime: lifetime,
        label: label,
      );

  // ── Pretty-print ──────────────────────────────────────────────────────────

  @override
  String toString() {
    final bar = _buildBar(utilizationRatio, 30);
    return '''
╔══════════════════════════════════════════╗
║       $label Memory Stats${''.padRight(11 - label.length)}║
╠══════════════════════════════════════════╣
║ Total Capacity : ${_fmt(totalCapacity).padLeft(12)}             ║
║ Used           : ${_fmt(_usedBytes).padLeft(12)} ($utilizationPercent)  ║
║ Free           : ${_fmt(freeBytes).padLeft(12)}             ║
║ Peak Usage     : ${_fmt(_peakUsage).padLeft(12)}             ║
║ Allocations    : ${_allocationCount.toString().padLeft(12)}             ║
║ Free calls     : ${_freeCount.toString().padLeft(12)}             ║
║ Resets         : ${_resetCount.toString().padLeft(12)}             ║
║ Lifetime       : ${lifetime.toString().padLeft(12)}             ║
╠══════════════════════════════════════════╣
║ Usage: [$bar]   ║
╚══════════════════════════════════════════╝''';
  }

  static String _buildBar(double ratio, int width) {
    final filled = (ratio * width).clamp(0, width).round();
    return ('█' * filled) + ('░' * (width - filled));
  }

  static String _fmt(int bytes) {
    if (bytes >= 1 << 30) {
      return '${(bytes / (1 << 30)).toStringAsFixed(2)} GB';
    } else if (bytes >= 1 << 20) {
      return '${(bytes / (1 << 20)).toStringAsFixed(2)} MB';
    } else if (bytes >= 1 << 10) {
      return '${(bytes / (1 << 10)).toStringAsFixed(2)} KB';
    }
    return '$bytes B';
  }
}

// ── ArenaSnapshot ─────────────────────────────────────────────────────────────

/// Immutable point-in-time snapshot of [ArenaStats].
///
/// Useful for logging, asserting invariants in tests, or comparing
/// stats before and after an operation.
class ArenaSnapshot {
  final int totalCapacity;
  final int usedBytes;
  final int freeBytes;
  final int peakUsage;
  final int allocationCount;
  final int freeCount;
  final int resetCount;
  final Duration lifetime;
  final String label;

  const ArenaSnapshot({
    required this.totalCapacity,
    required this.usedBytes,
    required this.freeBytes,
    required this.peakUsage,
    required this.allocationCount,
    required this.freeCount,
    required this.resetCount,
    required this.lifetime,
    required this.label,
  });

  /// Returns the delta between this snapshot and [other].
  ///
  /// Useful for measuring allocations made during a specific code section:
  /// ```dart
  /// final before = arena.stats.snapshot();
  /// doWork(arena);
  /// final after = arena.stats.snapshot();
  /// print(after.delta(before)); // how much memory doWork used
  /// ```
  ArenaSnapshotDelta delta(ArenaSnapshot baseline) => ArenaSnapshotDelta(
        bytesAllocated: usedBytes - baseline.usedBytes,
        allocCalls: allocationCount - baseline.allocationCount,
        freeCalls: freeCount - baseline.freeCount,
      );

  @override
  String toString() =>
      'ArenaSnapshot($label: used=$usedBytes, free=$freeBytes, '
      'allocs=$allocationCount, peak=$peakUsage)';
}

/// Delta between two [ArenaSnapshot] instances.
class ArenaSnapshotDelta {
  final int bytesAllocated;
  final int allocCalls;
  final int freeCalls;

  const ArenaSnapshotDelta({
    required this.bytesAllocated,
    required this.allocCalls,
    required this.freeCalls,
  });

  @override
  String toString() =>
      'Δ(bytes: +$bytesAllocated, allocs: +$allocCalls, frees: +$freeCalls)';
}
