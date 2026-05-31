import 'dart:ffi';

/// Memory alignment utilities for native heap management.
///
/// ## Why Alignment Matters
///
/// Modern CPUs and memory controllers operate most efficiently when data
/// structures reside at addresses that are **multiples of their size**.
/// Misaligned accesses may cause:
///
/// - **Bus errors** on strict-alignment architectures (ARM Cortex-A without
///   unaligned-access support, most RISC-V profiles).
/// - **Performance penalties** on x86/x64 — misaligned 64-bit reads that
///   straddle a cache-line boundary force two cache reads instead of one.
/// - **SIMD failures** — SSE2 `movdqa`, AVX `vmovdqa` and AVX-512 operations
///   require 16, 32 and 64-byte alignment respectively; misaligned access
///   raises #GP (General Protection Fault) in kernel mode.
///
/// ## The Core Math
///
/// ```
/// aligned = (offset + alignment - 1) & ~(alignment - 1)
/// ```
///
/// This works **only** when `alignment` is a power of two, because:
/// - `alignment - 1` produces a bitmask of the lower bits (e.g. 8-1=0b111)
/// - `~(alignment - 1)` inverts to keep upper bits (e.g. ~0b111 = ...11111000)
/// - ANDing rounds down, adding `alignment - 1` first rounds up
///
/// ## Predefined Constants
///
/// | Constant         | Value | Use Case                          |
/// |------------------|-------|-----------------------------------|
/// | [defaultAlign]   | 8     | General 64-bit native types       |
/// | [simdAlign]      | 16    | SSE/NEON SIMD operations          |
/// | [avxAlign]       | 32    | AVX/AVX2 wide SIMD                |
/// | [avx512Align]    | 64    | AVX-512 / cache-line boundary     |
/// | [cacheLineSize]  | 64    | Prevent false sharing (SMP/NUMA)  |
/// | [pageSize]       | 4096  | Virtual memory page alignment     |
abstract final class AlignmentUtils {
  // ── Predefined alignment constants ─────────────────────────────────────────

  /// Default alignment for general native allocations (8 bytes on 64-bit).
  ///
  /// Suitable for all scalar types up to `double` / `int64`.
  static const int defaultAlign = 8;

  /// Alias for [defaultAlign] for backward-compatibility.
  static const int defaultAlignment = 8;

  /// 16-byte alignment required by SSE2 / NEON intrinsics.
  static const int simdAlign = 16;

  /// 32-byte alignment required by AVX / AVX2 intrinsics.
  static const int avxAlign = 32;

  /// 64-byte alignment required by AVX-512 and cache-line-clean structs.
  static const int avx512Align = 64;

  /// Typical CPU cache-line size (64 bytes on x86-64 and ARM Cortex-A).
  ///
  /// Aligning hot read-only data to cache lines reduces cache misses.
  /// Aligning **mutable** data shared across threads prevents false sharing.
  static const int cacheLineSize = 64;

  /// OS virtual memory page size (4096 bytes on most platforms).
  ///
  /// Useful when interfacing with `mmap` or `VirtualAlloc`.
  static const int pageSize = 4096;

  // ── Core alignment math ────────────────────────────────────────────────────

  /// Rounds [offset] up to the nearest multiple of [alignment].
  ///
  /// [alignment] **must** be a power of two (assertion in debug mode).
  ///
  /// ## Examples
  ///
  /// ```dart
  /// AlignmentUtils.alignUp(0,  8)  // → 0    (already aligned)
  /// AlignmentUtils.alignUp(1,  8)  // → 8
  /// AlignmentUtils.alignUp(8,  8)  // → 8    (already aligned)
  /// AlignmentUtils.alignUp(9,  8)  // → 16
  /// AlignmentUtils.alignUp(15, 16) // → 16
  /// AlignmentUtils.alignUp(16, 16) // → 16
  /// AlignmentUtils.alignUp(17, 16) // → 32
  /// ```
  static int alignUp(int offset, int alignment) {
    assert(isPowerOfTwo(alignment),
        'alignment must be a power of two, got $alignment');
    return (offset + alignment - 1) & ~(alignment - 1);
  }

  /// Rounds [offset] **down** to the nearest multiple of [alignment].
  ///
  /// ```dart
  /// AlignmentUtils.alignDown(15, 8)  // → 8
  /// AlignmentUtils.alignDown(16, 8)  // → 16
  /// ```
  static int alignDown(int offset, int alignment) {
    assert(isPowerOfTwo(alignment),
        'alignment must be a power of two, got $alignment');
    return offset & ~(alignment - 1);
  }

  /// Returns `true` when [value] is already aligned to [alignment].
  ///
  /// ```dart
  /// AlignmentUtils.isAligned(16, 8)  // → true
  /// AlignmentUtils.isAligned(13, 8)  // → false
  /// ```
  static bool isAligned(int value, int alignment) {
    assert(isPowerOfTwo(alignment));
    return (value & (alignment - 1)) == 0;
  }

  /// Returns the number of padding bytes needed to align [offset].
  ///
  /// ```dart
  /// AlignmentUtils.paddingFor(10, 8)  // → 6  (10 + 6 = 16, aligned)
  /// AlignmentUtils.paddingFor(16, 8)  // → 0  (already aligned)
  /// ```
  static int paddingFor(int offset, int alignment) {
    return alignUp(offset, alignment) - offset;
  }

  /// Returns `true` when [n] is a power of two (and positive).
  ///
  /// The classic bit-trick: a power of two has exactly one bit set,
  /// so `n & (n-1)` clears that bit, yielding zero iff n is a power of two.
  static bool isPowerOfTwo(int n) => n > 0 && (n & (n - 1)) == 0;

  /// Returns the next power of two greater than or equal to [n].
  ///
  /// ```dart
  /// AlignmentUtils.nextPowerOfTwo(1)   // → 1
  /// AlignmentUtils.nextPowerOfTwo(5)   // → 8
  /// AlignmentUtils.nextPowerOfTwo(8)   // → 8
  /// AlignmentUtils.nextPowerOfTwo(100) // → 128
  /// ```
  static int nextPowerOfTwo(int n) {
    if (n <= 0) return 1;
    if (isPowerOfTwo(n)) return n;
    int p = 1;
    while (p < n) {
      p <<= 1;
    }
    return p;
  }

  /// Returns the natural alignment for a given element [size] in bytes.
  ///
  /// Follows the System V ABI convention used on Linux/macOS/Windows:
  /// - size 1 → align 1
  /// - size 2 → align 2
  /// - size 3–4 → align 4
  /// - size 5–8 → align 8
  /// - size > 8 → align 8 (max natural alignment on 64-bit)
  static int naturalAlignmentForSize(int size) {
    if (size <= 0) return 1;
    if (size == 1) return 1;
    if (size == 2) return 2;
    if (size <= 4) return 4;
    return 8;
  }

  /// Returns the natural alignment for native type [T].
  ///
  /// [elemSize] **must** be `sizeOf<T>()` evaluated at the concrete call site,
  /// because Dart's FFI `sizeOf` cannot accept generic type parameters at runtime.
  ///
  /// ```dart
  /// AlignmentUtils.alignmentOf<Float>(sizeOf<Float>())   // → 4
  /// AlignmentUtils.alignmentOf<Double>(sizeOf<Double>()) // → 8
  /// AlignmentUtils.alignmentOf<Int16>(sizeOf<Int16>())   // → 2
  /// ```
  static int alignmentOf<T extends SizedNativeType>(int elemSize) {
    return naturalAlignmentForSize(elemSize);
  }
}
