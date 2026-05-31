/// Thrown when an alignment constraint cannot be satisfied.
///
/// [AlignmentException] is raised by [AlignmentUtils] and the allocators
/// when a caller requests an alignment that is:
/// - Not a power of two (e.g. `alignment: 3`, `alignment: 6`).
/// - Zero or negative.
/// - Larger than the system's maximum supported alignment.
///
/// ## Example
///
/// ```dart
/// // This throws — 3 is not a power of two
/// arena.alloc(64, alignment: 3);
/// ```
class AlignmentException implements Exception {
  /// The invalid alignment value that was provided.
  final int alignment;

  /// Human-readable explanation of why this alignment is invalid.
  final String reason;

  const AlignmentException({
    required this.alignment,
    required this.reason,
  });

  @override
  String toString() =>
      'AlignmentException: alignment=$alignment — $reason\n'
      '  Valid alignments are positive powers of two: 1, 2, 4, 8, 16, 32, 64, ...';
}
