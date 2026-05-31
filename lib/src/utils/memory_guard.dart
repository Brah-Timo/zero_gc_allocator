import 'dart:ffi';

import '../arena/zero_gc_arena.dart';
import '../utils/alignment.dart';

/// A debug-mode boundary guard that detects writes beyond allocated regions.
///
/// [MemoryGuard] wraps a [ZeroGcArena] and inserts **canary regions** —
/// blocks of known magic bytes — immediately after each allocation.
/// After your code runs, [verify] scans these canary regions.
/// If any byte has changed, a buffer overflow occurred.
///
/// ## Design
///
/// ```
/// ┌─────────────────────────────────────────────────────────┐
/// │               Arena with guards                         │
/// ├────────────┬────────┬────────────┬────────┬─────────────┤
/// │ alloc #1   │ guard  │ alloc #2   │ guard  │   FREE      │
/// │ (user data)│ 8 bytes│ (user data)│ 8 bytes│             │
/// └────────────┴────────┴────────────┴────────┴─────────────┘
///                 ↑ CANARY_VALUE         ↑ CANARY_VALUE
/// ```
///
/// When [verify] is called, each guard block is checked against
/// [canaryValue]. Any deviation means the previous allocation was
/// written beyond its declared bounds.
///
/// ## Usage
///
/// ```dart
/// // Debug builds only — disable in production (guard overhead ~20 bytes/alloc)
/// final guard = MemoryGuard(
///   ZeroGcArena(size: 1.mb),
///   guardSize: 16,
/// );
///
/// final buf = guard.alloc(64);
/// // Simulate overflow:
/// for (int i = 0; i < 80; i++) (buf + i).value = 0xAA; // 16 bytes overflow!
///
/// guard.verify(); // throws MemoryOverflowDetected
///
/// guard.dispose();
/// ```
///
/// ## Production Use
///
/// [MemoryGuard] is intended for **debug / test builds only**.
/// The overhead (extra allocations + verification scan) makes it
/// unsuitable for production. Use [assert] blocks or compile-time
/// feature flags to exclude it.
class MemoryGuard {
  /// The underlying arena.
  final ZeroGcArena arena;

  /// Number of canary bytes inserted after each allocation.
  final int guardSize;

  /// Magic byte value used to fill guard regions.
  final int canaryByte;

  /// List of guard region addresses and associated metadata.
  final List<_GuardEntry> _guards = [];

  MemoryGuard(
    this.arena, {
    this.guardSize = 8,
    this.canaryByte = 0xAB,
  }) {
    if (guardSize < 1) {
      throw ArgumentError.value(guardSize, 'guardSize', 'Must be >= 1');
    }
  }

  /// Allocates [byteCount] bytes followed by a [guardSize]-byte canary region.
  ///
  /// Returns a pointer to the user data region (not the canary).
  ///
  /// ```dart
  /// final ptr = guard.alloc(128);
  /// // ptr..ptr+127 = user region (safe to write)
  /// // ptr+128..ptr+135 = guard/canary (must not be touched)
  /// ```
  Pointer<Uint8> alloc(int byteCount, {int alignment = AlignmentUtils.defaultAlignment}) {
    // Allocate user region + guard region in one bump
    final userPtr = arena.alloc(byteCount, alignment: alignment);
    final guardPtr = arena.alloc(guardSize, alignment: 1);

    // Fill guard with canary bytes
    for (int i = 0; i < guardSize; i++) {
      (guardPtr + i).value = canaryByte;
    }

    _guards.add(_GuardEntry(
      userAddress: userPtr.address,
      userSize: byteCount,
      guardAddress: guardPtr.address,
      guardSize: guardSize,
    ));

    return userPtr;
  }

  // ── Verification ──────────────────────────────────────────────────────────

  /// Scans all guard regions and throws [MemoryOverflowDetected] if any
  /// canary byte has been modified.
  ///
  /// Call this after the code under test to detect any buffer overflows.
  ///
  /// Returns the number of allocations verified.
  ///
  /// ```dart
  /// guard.verify(); // throws on corruption, returns count on success
  /// ```
  int verify() {
    for (final entry in _guards) {
      final guardPtr = Pointer<Uint8>.fromAddress(entry.guardAddress);
      for (int i = 0; i < entry.guardSize; i++) {
        final actual = (guardPtr + i).value;
        if (actual != canaryByte) {
          throw MemoryOverflowDetected(
            userAddress: entry.userAddress,
            userSize: entry.userSize,
            guardAddress: entry.guardAddress,
            byteOffset: i,
            expectedByte: canaryByte,
            actualByte: actual,
          );
        }
      }
    }
    return _guards.length;
  }

  /// Returns `true` if all guard regions are intact (no corruption).
  ///
  /// Safer alternative to [verify] when you only need a boolean result.
  bool isIntact() {
    try {
      verify();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Resets the guard list and the underlying arena.
  void reset() {
    _guards.clear();
    arena.reset();
  }

  /// Disposes the underlying arena.
  void dispose() {
    _guards.clear();
    arena.dispose();
  }

  /// Number of allocations currently tracked.
  int get allocationCount => _guards.length;

  @override
  String toString() =>
      'MemoryGuard(allocs: ${_guards.length}, guardSize: $guardSize, '
      'canaryByte: 0x${canaryByte.toRadixString(16)})';
}

// ── Internal entry ─────────────────────────────────────────────────────────

class _GuardEntry {
  final int userAddress;
  final int userSize;
  final int guardAddress;
  final int guardSize;

  const _GuardEntry({
    required this.userAddress,
    required this.userSize,
    required this.guardAddress,
    required this.guardSize,
  });
}

// ── Exception ─────────────────────────────────────────────────────────────

/// Thrown by [MemoryGuard.verify] when a buffer overflow is detected.
class MemoryOverflowDetected implements Exception {
  final int userAddress;
  final int userSize;
  final int guardAddress;
  final int byteOffset;
  final int expectedByte;
  final int actualByte;

  const MemoryOverflowDetected({
    required this.userAddress,
    required this.userSize,
    required this.guardAddress,
    required this.byteOffset,
    required this.expectedByte,
    required this.actualByte,
  });

  @override
  String toString() => '''
MemoryOverflowDetected!
  User region : 0x${userAddress.toRadixString(16)} — size $userSize bytes
  Guard region: 0x${guardAddress.toRadixString(16)} — corrupted at offset $byteOffset
  Expected    : 0x${expectedByte.toRadixString(16).padLeft(2, '0')}
  Actual      : 0x${actualByte.toRadixString(16).padLeft(2, '0')}

  This indicates a buffer overflow: code wrote ${byteOffset + 1} bytes beyond 
  the declared allocation boundary of $userSize bytes.
''';
}
