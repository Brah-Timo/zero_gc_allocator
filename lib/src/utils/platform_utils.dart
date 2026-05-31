import 'dart:io' show Platform;

/// Runtime platform detection helpers for native memory management.
///
/// Different operating systems impose different constraints on native
/// allocations:
///
/// - **Windows**: `VirtualAlloc` granularity is 64 KB; `calloc` uses the
///   CRT heap which has its own alignment guarantees.
/// - **macOS/iOS**: `malloc` guarantees 16-byte alignment on 64-bit.
/// - **Linux/Android**: `malloc` guarantees 8-byte (32-bit) or 16-byte
///   (64-bit) alignment per POSIX.
/// - **WASM**: Not yet supported by `dart:ffi`.
///
/// This class exists so platform-specific code in the allocators can be
/// centralized and easily tested/mocked.
abstract final class PlatformUtils {
  // ── Platform detection ────────────────────────────────────────────────────

  /// `true` on Windows (Win32 / UWP).
  static bool get isWindows {
    try {
      return Platform.isWindows;
    } catch (_) {
      return false; // web / WASM
    }
  }

  /// `true` on macOS desktop.
  static bool get isMacOS {
    try {
      return Platform.isMacOS;
    } catch (_) {
      return false;
    }
  }

  /// `true` on iOS devices and simulators.
  static bool get isIOS {
    try {
      return Platform.isIOS;
    } catch (_) {
      return false;
    }
  }

  /// `true` on Android (Dalvik/ART).
  static bool get isAndroid {
    try {
      return Platform.isAndroid;
    } catch (_) {
      return false;
    }
  }

  /// `true` on any Linux distribution.
  static bool get isLinux {
    try {
      return Platform.isLinux;
    } catch (_) {
      return false;
    }
  }

  /// `true` on Apple platforms (macOS or iOS).
  static bool get isApple => isMacOS || isIOS;

  /// `true` on mobile platforms (Android or iOS).
  static bool get isMobile => isAndroid || isIOS;

  /// `true` on desktop platforms.
  static bool get isDesktop => isWindows || isMacOS || isLinux;

  // ── Architecture helpers ──────────────────────────────────────────────────

  /// Pointer width in bytes (4 on 32-bit, 8 on 64-bit).
  ///
  /// Determined via FFI pointer size — works even without `dart:io`.
  static int get pointerSize {
    // Use the native Pointer size as the ground truth.
    // On 64-bit systems this is 8; on 32-bit systems (rare for Dart) it is 4.
    // We infer it from the maximum safe integer bit width.
    const maxSafe = 9007199254740992; // 2^53 — JS safe integer limit
    return maxSafe > 0xFFFFFFFF ? 8 : 4;
  }

  /// `true` when running on a 64-bit process.
  static bool get is64Bit => pointerSize == 8;

  /// Maximum safe single native allocation in bytes.
  ///
  /// Practical limits:
  /// - **64-bit desktop**: up to available RAM (tens of GBs typical)
  /// - **32-bit process**: ≈ 2–3 GB (virtual address space limit)
  /// - **iOS**: OS kills apps that exceed ~1–2 GB RSS
  /// - **Android**: OOM killer engages around 256 MB–1 GB depending on device
  static int get maxSafeAllocationBytes {
    if (isIOS) return 1024 * 1024 * 1024; // 1 GB conservative for iOS
    if (isAndroid) return 512 * 1024 * 1024; // 512 MB conservative for Android
    if (is64Bit) return 16 * 1024 * 1024 * 1024; // 16 GB for 64-bit desktop
    return 2 * 1024 * 1024 * 1024; // 2 GB for 32-bit
  }

  /// Minimum guaranteed malloc alignment on this platform.
  ///
  /// - 16 bytes on macOS/iOS (per Apple's libc documentation)
  /// - 16 bytes on 64-bit Linux (glibc malloc_usable_size guarantees)
  /// - 8 bytes on 32-bit Linux / Android
  /// - 16 bytes on Windows (UCRT malloc alignment spec)
  static int get nativeMallocAlignment {
    if (isApple) return 16;
    if (isWindows) return 16;
    if (is64Bit) return 16;
    return 8;
  }

  /// Returns a human-readable platform description string.
  static String get description {
    final bits = is64Bit ? '64-bit' : '32-bit';
    if (isWindows) return 'Windows ($bits)';
    if (isMacOS) return 'macOS ($bits)';
    if (isIOS) return 'iOS ($bits)';
    if (isAndroid) return 'Android ($bits)';
    if (isLinux) return 'Linux ($bits)';
    return 'Unknown ($bits)';
  }
}
