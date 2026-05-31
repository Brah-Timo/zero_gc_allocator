import 'dart:ffi';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

import '../arena/zero_gc_arena.dart';

/// A raw byte buffer on the native heap — the workhorse of zero-copy I/O.
///
/// [NativeBuffer] is a versatile byte-addressable memory region designed for:
///
/// - **Network I/O**: receive and send buffers for TCP/UDP/WebSocket.
/// - **Binary protocol parsing**: fixed-header + variable-body message
///   layouts (e.g. protobuf, msgpack, custom trading protocols).
/// - **Zero-copy serialization**: write directly to the native buffer,
///   then pass the pointer to a native socket `write` call.
/// - **Crypto operations**: temporary scratch space for HMAC, AES, etc.
///
/// ## Read/Write API
///
/// [NativeBuffer] provides primitive read/write methods for all integer
/// widths in both little-endian (default) and big-endian byte orders.
/// Multi-byte writes are intentionally explicit (no auto-endianness)
/// to match the mental model of binary protocol implementors.
///
/// ## Usage
///
/// ```dart
/// final arena = ZeroGcArena(size: 4.mb);
/// final buf = NativeBuffer(arena: arena, size: 1024);
///
/// // Write a binary header (little-endian)
/// buf.writeUint32LE(0, 0xDEADBEEF); // magic
/// buf.writeUint16LE(4, 128);          // payload length
/// buf.writeUint8(6, 0x01);            // version
///
/// // Read back
/// final magic = buf.readUint32LE(0); // → 0xDEADBEEF
///
/// // Zero-copy Dart view (no memcpy)
/// final view = buf.asByteData();
/// final crc  = view.getUint32(0, Endian.little);
///
/// arena.reset(); // buffer freed
/// ```
///
/// ## Endianness
///
/// Methods are suffixed with `LE` (little-endian) or `BE` (big-endian).
/// Omit the suffix for [Uint8]/[Int8] (no byte order for single bytes).
///
/// ## Lifetime
///
/// Identical to [NativeString]:
/// - Arena-backed: freed by arena.reset()/dispose().
/// - Standalone: freed by [dispose].
class NativeBuffer {
  final Pointer<Uint8> _ptr;
  final int size;
  final bool _ownsMemory;
  int _writePos = 0; // cursor for sequential write mode

  // ── Constructors ──────────────────────────────────────────────────────────

  NativeBuffer._(this._ptr, this.size, this._ownsMemory);

  /// Allocates [size] bytes, optionally from [arena].
  ///
  /// ```dart
  /// final buf = NativeBuffer(arena: arena, size: 65536);
  /// final buf = NativeBuffer(size: 4096); // standalone
  /// ```
  factory NativeBuffer({ZeroGcArena? arena, required int size}) {
    if (size <= 0) {
      throw ArgumentError.value(size, 'size', 'Must be positive');
    }
    final Pointer<Uint8> ptr;
    if (arena != null) {
      ptr = arena.alloc(size);
    } else {
      ptr = calloc.allocate<Uint8>(size);
    }
    return NativeBuffer._(ptr, size, arena == null);
  }

  /// Wraps an existing native pointer without taking ownership.
  factory NativeBuffer.fromPointer(Pointer<Uint8> ptr, int size) =>
      NativeBuffer._(ptr, size, false);

  // ── Uint8 ─────────────────────────────────────────────────────────────────

  int readUint8(int offset) {
    _checkOffset(offset, 1);
    return (_ptr + offset).value;
  }

  void writeUint8(int offset, int value) {
    _checkOffset(offset, 1);
    (_ptr + offset).value = value & 0xFF;
  }

  int readInt8(int offset) {
    final u = readUint8(offset);
    return u >= 0x80 ? u - 0x100 : u;
  }

  void writeInt8(int offset, int value) => writeUint8(offset, value & 0xFF);

  // ── Uint16 ────────────────────────────────────────────────────────────────

  int readUint16LE(int offset) {
    _checkOffset(offset, 2);
    return readUint8(offset) | (readUint8(offset + 1) << 8);
  }

  int readUint16BE(int offset) {
    _checkOffset(offset, 2);
    return (readUint8(offset) << 8) | readUint8(offset + 1);
  }

  void writeUint16LE(int offset, int value) {
    _checkOffset(offset, 2);
    writeUint8(offset, value & 0xFF);
    writeUint8(offset + 1, (value >> 8) & 0xFF);
  }

  void writeUint16BE(int offset, int value) {
    _checkOffset(offset, 2);
    writeUint8(offset, (value >> 8) & 0xFF);
    writeUint8(offset + 1, value & 0xFF);
  }

  // ── Uint32 ────────────────────────────────────────────────────────────────

  int readUint32LE(int offset) {
    _checkOffset(offset, 4);
    return readUint8(offset) |
        (readUint8(offset + 1) << 8) |
        (readUint8(offset + 2) << 16) |
        (readUint8(offset + 3) << 24);
  }

  int readUint32BE(int offset) {
    _checkOffset(offset, 4);
    return (readUint8(offset) << 24) |
        (readUint8(offset + 1) << 16) |
        (readUint8(offset + 2) << 8) |
        readUint8(offset + 3);
  }

  void writeUint32LE(int offset, int value) {
    _checkOffset(offset, 4);
    writeUint8(offset, value & 0xFF);
    writeUint8(offset + 1, (value >> 8) & 0xFF);
    writeUint8(offset + 2, (value >> 16) & 0xFF);
    writeUint8(offset + 3, (value >> 24) & 0xFF);
  }

  void writeUint32BE(int offset, int value) {
    _checkOffset(offset, 4);
    writeUint8(offset, (value >> 24) & 0xFF);
    writeUint8(offset + 1, (value >> 16) & 0xFF);
    writeUint8(offset + 2, (value >> 8) & 0xFF);
    writeUint8(offset + 3, value & 0xFF);
  }

  // ── Uint64 ────────────────────────────────────────────────────────────────

  int readUint64LE(int offset) {
    _checkOffset(offset, 8);
    return readUint32LE(offset) | (readUint32LE(offset + 4) << 32);
  }

  void writeUint64LE(int offset, int value) {
    _checkOffset(offset, 8);
    writeUint32LE(offset, value & 0xFFFFFFFF);
    writeUint32LE(offset + 4, (value >> 32) & 0xFFFFFFFF);
  }

  // ── Float / Double ────────────────────────────────────────────────────────

  double readFloat32LE(int offset) {
    _checkOffset(offset, 4);
    final bd = ByteData(4);
    for (int i = 0; i < 4; i++) bd.setUint8(i, readUint8(offset + i));
    return bd.getFloat32(0, Endian.little);
  }

  void writeFloat32LE(int offset, double value) {
    _checkOffset(offset, 4);
    final bd = ByteData(4);
    bd.setFloat32(0, value, Endian.little);
    for (int i = 0; i < 4; i++) writeUint8(offset + i, bd.getUint8(i));
  }

  double readFloat64LE(int offset) {
    _checkOffset(offset, 8);
    final bd = ByteData(8);
    for (int i = 0; i < 8; i++) bd.setUint8(i, readUint8(offset + i));
    return bd.getFloat64(0, Endian.little);
  }

  void writeFloat64LE(int offset, double value) {
    _checkOffset(offset, 8);
    final bd = ByteData(8);
    bd.setFloat64(0, value, Endian.little);
    for (int i = 0; i < 8; i++) writeUint8(offset + i, bd.getUint8(i));
  }

  // ── Bulk byte operations ──────────────────────────────────────────────────

  /// Writes [bytes] starting at [offset].
  void writeBytes(int offset, List<int> bytes) {
    _checkOffset(offset, bytes.length);
    for (int i = 0; i < bytes.length; i++) {
      writeUint8(offset + i, bytes[i]);
    }
  }

  /// Reads [count] bytes starting at [offset] into a Dart [List<int>].
  List<int> readBytes(int offset, int count) {
    _checkOffset(offset, count);
    return List<int>.generate(count, (i) => readUint8(offset + i));
  }

  // ── Sequential write cursor ───────────────────────────────────────────────

  /// Current write position (advances automatically with `append*` methods).
  int get writePosition => _writePos;

  void appendUint8(int value) {
    writeUint8(_writePos, value);
    _writePos++;
  }

  void appendUint16LE(int value) {
    writeUint16LE(_writePos, value);
    _writePos += 2;
  }

  void appendUint32LE(int value) {
    writeUint32LE(_writePos, value);
    _writePos += 4;
  }

  void appendUint64LE(int value) {
    writeUint64LE(_writePos, value);
    _writePos += 8;
  }

  void appendFloat64LE(double value) {
    writeFloat64LE(_writePos, value);
    _writePos += 8;
  }

  void appendBytes(List<int> bytes) {
    writeBytes(_writePos, bytes);
    _writePos += bytes.length;
  }

  void resetWritePosition() => _writePos = 0;

  // ── Utility ───────────────────────────────────────────────────────────────

  /// Sets all bytes in this buffer to zero.
  void clear() {
    for (int i = 0; i < size; i++) {
      (_ptr + i).value = 0;
    }
    _writePos = 0;
  }

  /// Returns a zero-copy [ByteData] view over this buffer's native memory.
  ///
  /// The returned [ByteData] shares memory with this buffer.
  /// **Do not use after arena.reset() or arena.dispose().**
  ByteData asByteData() {
    return _ptr.cast<Uint8>().asTypedList(size).buffer.asByteData();
  }

  /// Returns a zero-copy [Uint8List] view over this buffer.
  Uint8List asUint8List() {
    return _ptr.cast<Uint8>().asTypedList(size);
  }

  /// Raw [Pointer<Uint8>] for passing to native APIs.
  Pointer<Uint8> get pointer => _ptr;

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  void dispose() {
    if (_ownsMemory) calloc.free(_ptr);
  }

  void _checkOffset(int offset, int width) {
    if (offset < 0 || offset + width > size) {
      throw RangeError(
        'NativeBuffer: offset $offset + width $width exceeds size $size',
      );
    }
  }

  @override
  String toString() =>
      'NativeBuffer(size: $size, writePos: $_writePos, '
      'addr: 0x${_ptr.address.toRadixString(16)})';
}
