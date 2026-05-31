import 'dart:ffi';
import 'dart:convert';
import 'package:ffi/ffi.dart';

import '../arena/zero_gc_arena.dart';

/// A null-terminated UTF-8 string on the native heap, outside the GC.
///
/// [NativeString] allocates a UTF-8 encoded, null-terminated byte array
/// on the native heap (either arena-backed or standalone). It is ideal for:
///
/// - Passing strings to native C APIs via FFI without repeated encoding.
/// - High-throughput log formatting where GC pressure from [String]
///   concatenation would be problematic.
/// - Protocol message fields with known maximum lengths.
///
/// ## Usage
///
/// ```dart
/// final arena = ZeroGcArena(size: 4.mb);
///
/// // Arena-backed — freed automatically when arena resets
/// final greeting = NativeString.fromDart('Hello, world!', arena: arena);
/// print(greeting.toDartString()); // Hello, world!
/// print(greeting.byteLength);     // 13
///
/// // Concatenate into a pre-allocated destination
/// final combined = NativeString.concat(
///   ['GET ', '/api/orders', ' HTTP/1.1\r\n'],
///   arena: arena,
/// );
///
/// arena.reset(); // both strings freed
/// arena.dispose();
/// ```
///
/// ## Encoding
///
/// All strings are stored as **UTF-8** with a null terminator.
/// The [byteLength] property returns the number of UTF-8 bytes,
/// **not** the number of characters (they differ for non-ASCII text).
///
/// ## Lifetime
///
/// Like all native allocations, [NativeString] must not be used after
/// the owning arena has been reset or disposed, or after [dispose] is
/// called on a standalone instance.
class NativeString {
  final Pointer<Uint8> _ptr;

  /// Number of UTF-8 bytes (excluding null terminator).
  final int byteLength;

  final bool _ownsMemory;

  // ── Constructors ──────────────────────────────────────────────────────────

  NativeString._(this._ptr, this.byteLength, this._ownsMemory);

  /// Encodes [s] as UTF-8 and allocates it on the native heap.
  ///
  /// If [arena] is provided, the allocation comes from the arena.
  /// Otherwise it is a standalone allocation — call [dispose] when done.
  ///
  /// An extra byte is allocated for the null terminator.
  ///
  /// ```dart
  /// final s = NativeString.fromDart('Hello', arena: arena);
  /// ```
  factory NativeString.fromDart(String s, {ZeroGcArena? arena}) {
    final bytes = utf8.encode(s);
    final totalBytes = bytes.length + 1; // +1 for null terminator

    final Pointer<Uint8> ptr;
    if (arena != null) {
      ptr = arena.alloc(totalBytes);
    } else {
      ptr = calloc.allocate<Uint8>(totalBytes);
    }

    for (int i = 0; i < bytes.length; i++) {
      (ptr + i).value = bytes[i];
    }
    (ptr + bytes.length).value = 0; // null terminator

    return NativeString._(ptr, bytes.length, arena == null);
  }

  /// Concatenates multiple [strings] into a single native allocation.
  ///
  /// Equivalent to joining them and calling [fromDart], but avoids
  /// creating an intermediate Dart [String] object.
  ///
  /// ```dart
  /// final line = NativeString.concat(
  ///   ['Content-Length: ', contentLength.toString(), '\r\n'],
  ///   arena: headerArena,
  /// );
  /// ```
  factory NativeString.concat(List<String> strings, {ZeroGcArena? arena}) {
    // Encode all parts
    final parts = strings.map(utf8.encode).toList();
    final totalBytes = parts.fold<int>(0, (sum, p) => sum + p.length);

    final Pointer<Uint8> ptr;
    if (arena != null) {
      ptr = arena.alloc(totalBytes + 1);
    } else {
      ptr = calloc.allocate<Uint8>(totalBytes + 1);
    }

    int offset = 0;
    for (final part in parts) {
      for (final byte in part) {
        (ptr + offset).value = byte;
        offset++;
      }
    }
    (ptr + offset).value = 0; // null terminator

    return NativeString._(ptr, totalBytes, arena == null);
  }

  /// Creates a [NativeString] from an already-allocated null-terminated
  /// native pointer. The length is inferred by scanning for the null byte.
  ///
  /// Use this for C API return values.
  factory NativeString.fromPointer(Pointer<Uint8> ptr) {
    int len = 0;
    while ((ptr + len).value != 0) {
      len++;
    }
    return NativeString._(ptr, len, false);
  }

  // ── Access ────────────────────────────────────────────────────────────────

  /// Decodes the native string back to a Dart [String].
  ///
  /// This allocates a Dart object — call sparingly in hot paths.
  String toDartString() {
    final bytes = List<int>.generate(byteLength, (i) => (_ptr + i).value);
    return utf8.decode(bytes);
  }

  /// Returns the raw [Pointer<Uint8>] to the null-terminated bytes.
  ///
  /// Suitable for passing to C APIs expecting `char*`.
  Pointer<Uint8> get pointer => _ptr;

  /// Reads the byte at [index] (0-based, within [byteLength]).
  int byteAt(int index) {
    if (index < 0 || index >= byteLength) {
      throw RangeError.index(index, this, 'index', null, byteLength);
    }
    return (_ptr + index).value;
  }

  /// `true` when the string is empty (byteLength == 0).
  bool get isEmpty => byteLength == 0;

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  /// Frees native memory for standalone instances.
  /// No-op when backed by an arena.
  void dispose() {
    if (_ownsMemory) calloc.free(_ptr);
  }

  @override
  String toString() => 'NativeString(bytes: $byteLength, '
      'addr: 0x${_ptr.address.toRadixString(16)})';

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is NativeString) {
      if (byteLength != other.byteLength) return false;
      for (int i = 0; i < byteLength; i++) {
        if (byteAt(i) != other.byteAt(i)) return false;
      }
      return true;
    }
    return false;
  }

  @override
  int get hashCode => toDartString().hashCode;
}
