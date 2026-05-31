import 'zero_gc_arena.dart';
import '../exceptions/arena_exception.dart';

/// A saved cursor checkpoint within a [ZeroGcArena].
///
/// Created via [ZeroGcArena.saveCheckpoint] and restored via
/// [ZeroGcArena.restoreCheckpoint] or the convenience [restore] method.
///
/// ## Purpose
///
/// [ArenaRegion] enables **scoped** allocation patterns: allocate freely
/// during a logical block, then discard everything in a single O(1) restore —
/// without touching the GC.
///
/// This is the Dart equivalent of C++ stack-scoped allocation or the
/// "mark / release" pattern in classic arena allocators.
///
/// ## Example: per-draw-call temporary buffers (game rendering)
///
/// ```dart
/// void renderMesh(ZeroGcArena frameArena, Mesh mesh) {
///   // Save cursor before any temporary allocations
///   final region = frameArena.saveCheckpoint();
///
///   final transformedVerts = frameArena.allocTyped<Float>(mesh.vertexCount * 3);
///   final lightmapUVs      = frameArena.allocTyped<Float>(mesh.vertexCount * 2);
///   final skinningMatrices = frameArena.allocTyped<Float>(mesh.boneCount * 16);
///
///   // ... GPU upload, draw call submission ...
///
///   // All three allocations freed atomically in O(1)
///   frameArena.restoreCheckpoint(region);
///   // (or simply: region.restore())
/// }
/// ```
///
/// ## Nesting
///
/// Regions can be nested freely — they form a logical stack:
///
/// ```dart
/// final r1 = arena.saveCheckpoint(); // offset = 0
/// arena.alloc(100);                  // offset = 100 (approx)
/// final r2 = arena.saveCheckpoint(); // offset = 100
/// arena.alloc(200);                  // offset = 300
///
/// arena.restoreCheckpoint(r2);       // offset → 100 (r2 freed)
/// arena.restoreCheckpoint(r1);       // offset → 0   (r1 freed)
/// ```
///
/// **Important**: always restore in reverse order. Restoring an outer
/// region before an inner one will cause the inner region's
/// [offsetAtCreation] to be ahead of the cursor, which raises
/// [ArenaRegionException].
class ArenaRegion {
  /// The arena that owns this region.
  final ZeroGcArena arena;

  /// The arena cursor value at the moment [saveCheckpoint] was called.
  ///
  /// On [restore] the arena's cursor is rewound to this value.
  final int offsetAtCreation;

  bool _restored = false;

  ArenaRegion({
    required this.arena,
    required this.offsetAtCreation,
  });

  // ── State ──────────────────────────────────────────────────────────────────

  /// `true` after [restore] or [ZeroGcArena.restoreCheckpoint] has been called.
  bool get isRestored => _restored;

  /// `true` if this region still represents live (unreleased) allocations.
  bool get isActive => !_restored;

  /// Bytes allocated within this region (since [saveCheckpoint] was called).
  ///
  /// Returns 0 if the region has already been restored.
  int get bytesAllocated =>
      _restored ? 0 : (arena.usedBytes - offsetAtCreation).clamp(0, arena.capacity);

  // ── Restore ────────────────────────────────────────────────────────────────

  /// Restores the arena cursor to [offsetAtCreation], freeing all allocations
  /// made after this region was created.
  ///
  /// Equivalent to calling `arena.restoreCheckpoint(this)`.
  ///
  /// Throws [ArenaRegionException] if already restored.
  /// Throws [ArenaDisposedException] if the arena has been disposed.
  void restore() {
    if (_restored) {
      throw ArenaRegionException(
        'Region at offset $offsetAtCreation has already been restored. '
        'Double-restore indicates a logic error.',
      );
    }
    arena.restoreCheckpoint(this);
  }

  // ── Internal ───────────────────────────────────────────────────────────────

  /// Called by [ZeroGcArena.restoreCheckpoint] upon successful restore.
  void markRestored() => _restored = true;

  @override
  String toString() => 'ArenaRegion('
      'offset: $offsetAtCreation, '
      'active: $isActive, '
      'bytesAllocated: $bytesAllocated)';
}
