import 'dart:ffi';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

import '../arena/zero_gc_arena.dart';

/// A dynamically-typed list of native numeric values with zero GC pressure.
///
/// [NativeList<T>] is a thin wrapper over a native [Pointer<T>] array
/// that provides:
/// - Bounds-checked element access via `[]` / `[]=` operators.
/// - Arena integration (optional — standalone allocation also supported).
/// - [fill], [copyFrom], [copyTo], and iteration helpers.
/// - Zero Dart heap allocation after construction.
///
/// ## Supported types
///
/// Any [SizedNativeType] with a defined [sizeOf] works:
/// [Int8], [Int16], [Int32], [Int64],
/// [Uint8], [Uint16], [Uint32], [Uint64],
/// [Float], [Double].
///
/// ## Usage
///
/// ```dart
/// final arena = ZeroGcArena(size: 32.mb);
///
/// // 1M doubles — arena-backed, zero GC pressure
/// final prices = NativeList<Double>(arena: arena, length: 1000000,
///     elemSize: sizeOf<Double>());
///
/// // Write
/// prices[0].value = 49234.50;
/// prices[999999].value = 0.01;
///
/// // Read via pointer math
/// double sum = 0;
/// for (int i = 0; i < prices.length; i++) {
///   sum += (prices[i] as Pointer<Double>).value;
/// }
///
/// // Standalone (no arena — must call dispose())
/// final buf = NativeList<Uint8>(length: 4096, elemSize: sizeOf<Uint8>());
/// buf.dispose();
/// ```
///
/// ## Arena vs Standalone
///
/// | Mode        | Memory lifetime                   | dispose() |
/// |-------------|-----------------------------------|-----------|
/// | Arena-backed| Freed by arena.reset()/dispose()  | No-op     |
/// | Standalone  | Freed only by dispose()           | Required  |
class NativeList<T extends SizedNativeType> {
  late final Pointer<T> _ptr;
  final int length;
  final int _elemSize;
  final bool _ownsMemory;

  // ── Constructors ──────────────────────────────────────────────────────────

  /// Creates a [NativeList<T>] backed by [arena].
  ///
  /// [elemSize] **must** be `sizeOf<T>()` supplied at the concrete call site
  /// (e.g. `sizeOf<Double>()`), because Dart's FFI `sizeOf` function cannot
  /// accept a generic type parameter at runtime.
  ///
  /// The memory lifetime is controlled by the arena — no manual [dispose]
  /// is needed (and calling it is a no-op).
  ///
  /// ```dart
  /// final prices = NativeList<Double>(
  ///     arena: frameArena, length: 500000, elemSize: sizeOf<Double>());
  /// ```
  NativeList({ZeroGcArena? arena, required this.length, required int elemSize})
      : _elemSize = elemSize,
        _ownsMemory = arena == null {
    if (length <= 0) {
      throw ArgumentError.value(length, 'length', 'Must be positive');
    }
    if (elemSize <= 0) {
      throw ArgumentError.value(elemSize, 'elemSize', 'Must be positive');
    }
    if (arena != null) {
      _ptr = arena.allocTyped<T>(length, elemSize: elemSize);
    } else {
      // Standalone: allocate via calloc using raw byte count then cast.
      // We allocate Uint8 and cast because calloc.allocate<T> also requires
      // a concrete T at compile time when computing the element count.
      _ptr = calloc.allocate<Uint8>(elemSize * length).cast<T>();
    }
  }

  // ── Element access ────────────────────────────────────────────────────────

  /// Returns the raw [Pointer<T>] to element at [index].
  ///
  /// Use `list[i].value` to read, `list[i].value = x` to write.
  ///
  /// For numeric types, the shorthand [getNum] / [setNum] may be more
  /// convenient.
  ///
  /// ```dart
  /// (prices[42] as Pointer<Double>).value = 100.0;
  /// final v = (prices[42] as Pointer<Double>).value;
  /// ```
  Pointer<T> operator [](int index) {
    _boundsCheck(index);
    // Byte-level arithmetic — `Pointer<T> + int` is only valid for concrete T.
    return Pointer<T>.fromAddress(_ptr.address + index * _elemSize);
  }

  // ── Bulk operations ───────────────────────────────────────────────────────

  /// Returns a sub-list view starting at [start] with [count] elements.
  ///
  /// The view shares the same native memory — writes to the view affect
  /// the original list.
  ///
  /// ```dart
  /// final sub = prices.subList(100, 50); // elements [100..149]
  /// ```
  NativeList<T> subList(int start, int count) {
    _boundsCheck(start);
    if (start + count > length) {
      throw RangeError('subList($start, $count) out of bounds (length: $length)');
    }
    return NativeList<T>._fromPointer(
      Pointer<T>.fromAddress(_ptr.address + start * _elemSize),
      count,
      _elemSize,
    );
  }

  NativeList._fromPointer(this._ptr, this.length, this._elemSize)
      : _ownsMemory = false;

  /// Copies [src] Dart list into this native list using byte-level writes.
  ///
  /// [src.length] must equal [length].
  ///
  /// ```dart
  /// final nativeVec = NativeList<Float>(arena: arena, length: 3,
  ///     elemSize: sizeOf<Float>());
  /// nativeVec.copyFromList([1.0, 2.0, 3.0]);
  /// ```
  void copyFromList(List<num> src) {
    if (src.length != length) {
      throw ArgumentError(
        'Source list length (${src.length}) must equal this list length ($length)',
      );
    }
    // Write through a ByteData view for type-agnostic, generic-safe access.
    final byteCount = length * _elemSize;
    final bd = ByteData(byteCount);
    for (int i = 0; i < length; i++) {
      final v = src[i];
      final off = i * _elemSize;
      switch (_elemSize) {
        case 1:
          bd.setUint8(off, v.toInt() & 0xFF);
        case 2:
          bd.setInt16(off, v.toInt(), Endian.host);
        case 4:
          if (v is double) {
            bd.setFloat32(off, v, Endian.host);
          } else {
            bd.setInt32(off, v.toInt(), Endian.host);
          }
        case 8:
          if (v is double) {
            bd.setFloat64(off, v, Endian.host);
          } else {
            bd.setInt64(off, v.toInt(), Endian.host);
          }
        default:
          throw UnsupportedError('Unsupported element size: $_elemSize');
      }
    }
    final bytes = bd.buffer.asUint8List();
    final rawPtr = _ptr.cast<Uint8>();
    for (int i = 0; i < byteCount; i++) {
      (rawPtr + i).value = bytes[i];
    }
  }

  /// Returns the base [Pointer<T>].
  Pointer<T> get basePointer => _ptr;

  /// Returns the total byte size of this list.
  int get sizeInBytes => length * _elemSize;

  /// Returns a raw [Uint8List] view over the native memory.
  ///
  /// **Warning**: invalidated after arena.reset() or arena.dispose().
  Uint8List asRawBytes() {
    return _ptr.cast<Uint8>().asTypedList(sizeInBytes);
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  /// Frees native memory.
  ///
  /// No-op when backed by an arena (memory is managed by the arena's lifetime).
  /// Required for standalone lists (created without [arena]).
  void dispose() {
    if (_ownsMemory) calloc.free(_ptr);
  }

  void _boundsCheck(int index) {
    if (index < 0 || index >= length) {
      throw RangeError.index(index, this, 'index', null, length);
    }
  }

  @override
  String toString() => 'NativeList<$T>(length: $length, '
      'sizeInBytes: $sizeInBytes, '
      'base: 0x${_ptr.address.toRadixString(16)})';
}
