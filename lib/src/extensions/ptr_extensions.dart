import 'dart:ffi';
import 'dart:typed_data';

/// Ergonomic extensions on [Pointer] types for common native memory operations.
///
/// These extensions reduce boilerplate in FFI-heavy code by providing
/// idiomatic Dart syntax for pointer arithmetic, typed views, and
/// bulk memory operations.
///
/// ## Usage
///
/// ```dart
/// import 'package:zero_gc_allocator/zero_gc_allocator.dart';
///
/// final ptr = arena.alloc(256);
///
/// // Fill 256 bytes with 0xAB
/// ptr.fill(256, 0xAB);
///
/// // Copy 128 bytes from another pointer
/// ptr.copyFrom(srcPtr, 128);
///
/// // Typed sub-pointer (byte 8 onwards, treated as Int32)
/// final int32ptr = ptr.castAt<Int32>(8);
///
/// // Check alignment
/// print(ptr.isAlignedTo(16)); // true/false
/// ```
extension Uint8PointerExtensions on Pointer<Uint8> {
  // ── Memory fill ──────────────────────────────────────────────────────────

  /// Fills [count] bytes starting at this pointer with [byteValue].
  ///
  /// ```dart
  /// ptr.fill(1024, 0); // zero out 1 KB
  /// ptr.fill(64, 0xFF); // set 64 bytes to 0xFF
  /// ```
  void fill(int count, int byteValue) {
    final v = byteValue & 0xFF;
    for (int i = 0; i < count; i++) {
      (this + i).value = v;
    }
  }

  /// Zeroes [count] bytes starting at this pointer.
  void zeroFill(int count) => fill(count, 0);

  // ── Memory copy ───────────────────────────────────────────────────────────

  /// Copies [count] bytes from [src] into this pointer's location.
  ///
  /// Equivalent to C `memcpy(dst, src, count)`.
  ///
  /// ```dart
  /// dst.copyFrom(src, 512);
  /// ```
  void copyFrom(Pointer<Uint8> src, int count) {
    for (int i = 0; i < count; i++) {
      (this + i).value = (src + i).value;
    }
  }

  /// Copies [count] bytes from a Dart [List<int>] into this pointer.
  void copyFromList(List<int> list, {int dstOffset = 0}) {
    final count = list.length;
    for (int i = 0; i < count; i++) {
      (this + dstOffset + i).value = list[i] & 0xFF;
    }
  }

  // ── Typed cast at offset ──────────────────────────────────────────────────

  /// Returns a typed pointer [Pointer<T>] at byte [byteOffset] from this.
  ///
  /// ```dart
  /// final base = arena.alloc(256);
  /// final header = base.castAt<Uint32>(0);  // Uint32 at byte 0
  /// final length = base.castAt<Uint16>(4);  // Uint16 at byte 4
  /// ```
  Pointer<T> castAt<T extends NativeType>(int byteOffset) {
    return Pointer<T>.fromAddress(address + byteOffset);
  }

  // ── Alignment checks ──────────────────────────────────────────────────────

  /// Returns `true` if this pointer's address is aligned to [alignment].
  ///
  /// ```dart
  /// ptr.isAlignedTo(16); // true for SIMD-safe addresses
  /// ```
  bool isAlignedTo(int alignment) => (address % alignment) == 0;

  // ── Byte views ────────────────────────────────────────────────────────────

  /// Returns a zero-copy [ByteData] view over [count] bytes at this pointer.
  ///
  /// **Warning**: The [ByteData] shares native memory — do not use after
  /// the owning arena is reset or disposed.
  ByteData viewAs(int count) {
    return asTypedList(count).buffer.asByteData();
  }

  // ── Byte comparison ───────────────────────────────────────────────────────

  /// Returns `true` if [count] bytes at this pointer equal [count] bytes at [other].
  ///
  /// Equivalent to C `memcmp(this, other, count) == 0`.
  bool memEquals(Pointer<Uint8> other, int count) {
    for (int i = 0; i < count; i++) {
      if ((this + i).value != (other + i).value) return false;
    }
    return true;
  }

  // ── Debug ─────────────────────────────────────────────────────────────────

  /// Returns a hex dump of [count] bytes as a formatted string.
  ///
  /// Useful for debugging binary protocol buffers.
  ///
  /// ```
  /// DE AD BE EF 00 01 02 03  04 05 06 07 08 09 0A 0B
  /// 0C 0D 0E 0F 10 11 12 13  14 15 16 17 18 19 1A 1B
  /// ```
  String hexDump(int count, {int columns = 16}) {
    final sb = StringBuffer();
    for (int i = 0; i < count; i++) {
      if (i > 0 && i % columns == 0) sb.write('\n');
      if (i > 0 && i % (columns ~/ 2) == 0 && i % columns != 0) sb.write(' ');
      sb.write((this + i).value.toRadixString(16).padLeft(2, '0').toUpperCase());
      if (i % columns != columns - 1 && i < count - 1) sb.write(' ');
    }
    return sb.toString();
  }

  /// Returns this pointer's address as a formatted hex string.
  ///
  /// ```dart
  /// print(ptr.toHexAddress()); // 0x7FFF1234ABCD
  /// ```
  String toHexAddress() => '0x${address.toRadixString(16).toUpperCase()}';
}

// ── Generic pointer extensions ─────────────────────────────────────────────

/// Extensions available on any typed [Pointer<T>].
extension TypedPointerExtensions<T extends NativeType> on Pointer<T> {
  /// Returns this pointer's address as a formatted hex string.
  String toHexAddress() => '0x${address.toRadixString(16).toUpperCase()}';

  /// Returns `true` if this pointer is aligned to [alignment] bytes.
  bool isAlignedTo(int alignment) => (address % alignment) == 0;

  /// Casts this pointer to [Pointer<Uint8>] for byte-level access.
  Pointer<Uint8> get asBytes => cast<Uint8>();

  /// Returns a [Pointer<U>] to the same address, reinterpreting the type.
  ///
  /// ```dart
  /// final floatPtr = myInt32Ptr.reinterpretAs<Float>();
  /// ```
  Pointer<U> reinterpretAs<U extends NativeType>() => cast<U>();

  /// `true` if this is the null pointer (address == 0).
  bool get isNull => address == 0;

  /// `true` if this is a valid (non-null) pointer.
  bool get isNotNull => address != 0;
}
