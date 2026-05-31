/// Human-readable size literals for native memory allocation.
///
/// Converts numeric literals to byte counts using familiar unit suffixes.
/// Works on any [num] subtype (int, double).
///
/// ## Usage
///
/// ```dart
/// final arena = ZeroGcArena(size: 512.mb);
/// final arena = ZeroGcArena(size: 2.gb);
/// final pool  = ZeroGcPool(blockSize: 64, capacity: 10000);
/// final buf   = NativeBuffer(size: 4.kb);
///
/// // Double literals are supported too:
/// final arena2 = ZeroGcArena(size: 1.5.gb);  // 1,610,612,736 bytes
/// ```
///
/// ## Unit Table
///
/// | Suffix | Multiplier      | Example           |
/// |--------|-----------------|-------------------|
/// | .bytes | × 1             | 1.bytes  → 1      |
/// | .kb    | × 1,024         | 1.kb     → 1,024  |
/// | .mb    | × 1,048,576     | 1.mb     → 1M     |
/// | .gb    | × 1,073,741,824 | 1.gb     → 1G     |
/// | .tb    | × 1,099,511,628 | 1.tb     → 1T     |
extension SizeExtension on num {
  /// Returns this value as raw bytes (identity conversion).
  ///
  /// Useful for explicit documentation of intent:
  /// ```dart
  /// final magic = ZeroGcArena(size: 4096.bytes); // clearly 4096 bytes
  /// ```
  int get bytes => toInt();

  /// Converts to kilobytes: `n.kb == n * 1024`.
  ///
  /// ```dart
  /// 16.kb == 16384
  /// ```
  int get kb => (this * 1024).toInt();

  /// Converts to megabytes: `n.mb == n * 1024 * 1024`.
  ///
  /// ```dart
  /// 256.mb == 268435456
  /// ```
  int get mb => (this * 1024 * 1024).toInt();

  /// Converts to gigabytes: `n.gb == n * 1024^3`.
  ///
  /// ```dart
  /// 2.gb == 2147483648
  /// ```
  int get gb => (this * 1024 * 1024 * 1024).toInt();

  /// Converts to terabytes: `n.tb == n * 1024^4`.
  ///
  /// Primarily useful for virtual address-space reservations on 64-bit systems.
  /// Most 32-bit platforms cannot satisfy allocations above ~3 GB.
  ///
  /// ```dart
  /// 1.tb == 1099511627776
  /// ```
  int get tb => (this * 1024 * 1024 * 1024 * 1024).toInt();

  /// Formats this byte count as a human-readable string.
  ///
  /// ```dart
  /// 1.gb.toSizeString()   // → "1.00 GB"
  /// 512.mb.toSizeString() // → "512.00 MB"
  /// 1500.toSizeString()   // → "1.46 KB"
  /// ```
  String toSizeString() {
    final n = toDouble();
    if (n >= 1024.0 * 1024 * 1024 * 1024) {
      return '${(n / (1024.0 * 1024 * 1024 * 1024)).toStringAsFixed(2)} TB';
    } else if (n >= 1024.0 * 1024 * 1024) {
      return '${(n / (1024.0 * 1024 * 1024)).toStringAsFixed(2)} GB';
    } else if (n >= 1024.0 * 1024) {
      return '${(n / (1024.0 * 1024)).toStringAsFixed(2)} MB';
    } else if (n >= 1024.0) {
      return '${(n / 1024.0).toStringAsFixed(2)} KB';
    }
    return '${toInt()} B';
  }
}
