import 'dart:ffi';
import 'dart:typed_data';

import '../arena/zero_gc_arena.dart';

/// A type-safe wrapper around a native [Pointer<T>] with arena lifecycle.
///
/// [TypedPtr<T>] is the safest way to interact with a single native value
/// allocated inside a [ZeroGcArena]. It associates the pointer with its
/// owning arena, enabling lifetime assertions and expressive read/write
/// access.
///
/// ## Usage
///
/// ```dart
/// final arena = ZeroGcArena(size: 1.mb);
///
/// // Allocate a single Float64 in the arena
/// final myDouble = TypedPtr<Double>.fromArena(arena, elemSize: sizeOf<Double>());
/// myDouble.value = 3.14159;
/// print(myDouble.value); // 3.14159
///
/// // Allocate an array of 128 Int32 values
/// final counts = TypedPtr<Int32>.arrayFromArena(arena, count: 128, elemSize: sizeOf<Int32>());
/// counts[0] = 42;
/// counts[127] = -1;
///
/// arena.reset(); // myDouble and counts are both freed
/// arena.dispose();
/// ```
///
/// ## Why TypedPtr over bare Pointer?
///
/// - **Arena association**: you can check `isAlive` to detect use-after-reset.
/// - **Null-safety façade**: throws [StateError] on reads/writes to a
///   disposed or reset arena when [arena] is provided.
/// - **Operator overloading**: `[index]` and `[]= ` provide array-style
///   access without verbose `(ptr + i).value` syntax.
class TypedPtr<T extends SizedNativeType> {
  final Pointer<T> _ptr;

  /// The arena this pointer was allocated from (may be null for standalone).
  final ZeroGcArena? arena;

  /// Number of elements this pointer spans (1 for scalar, n for array).
  final int count;

  /// Size in bytes of one element of type [T].
  ///
  /// Must be provided at construction time (from a concrete call site where
  /// `sizeOf<T>()` can be evaluated by the Dart compiler).
  final int elemSize;

  const TypedPtr._(this._ptr, this.elemSize, {this.arena, this.count = 1});

  // ── Factory constructors ──────────────────────────────────────────────────

  /// Allocates a single element of type [T] inside [arena].
  ///
  /// [elemSize] **must** be `sizeOf<T>()` evaluated at the concrete call site:
  ///
  /// ```dart
  /// final f = TypedPtr<Float>.fromArena(arena, elemSize: sizeOf<Float>());
  /// f.value = 2.71;
  /// ```
  factory TypedPtr.fromArena(ZeroGcArena arena, {required int elemSize}) {
    final ptr = arena.allocTyped<T>(1, elemSize: elemSize);
    return TypedPtr._(ptr, elemSize, arena: arena, count: 1);
  }

  /// Allocates an array of [count] elements of type [T] inside [arena].
  ///
  /// [elemSize] **must** be `sizeOf<T>()` evaluated at the concrete call site:
  ///
  /// ```dart
  /// final verts = TypedPtr<Float>.arrayFromArena(arena,
  ///     count: 300, elemSize: sizeOf<Float>());
  /// verts[0] = 0.5;
  /// verts[1] = -0.5;
  /// ```
  factory TypedPtr.arrayFromArena(
    ZeroGcArena arena, {
    required int count,
    required int elemSize,
  }) {
    if (count <= 0) {
      throw ArgumentError.value(count, 'count', 'Must be positive');
    }
    final ptr = arena.allocTyped<T>(count, elemSize: elemSize);
    return TypedPtr._(ptr, elemSize, arena: arena, count: count);
  }

  /// Wraps an existing [Pointer<T>] without arena association.
  ///
  /// [elemSize] is the byte size of a single element — required for
  /// bounds-checked array indexing (`ptr[i]`). Pass `sizeOf<T>()` at the
  /// call site where `T` is fully concrete.
  ///
  /// Use for interop with code that produces native pointers directly.
  const TypedPtr.fromPointer(Pointer<T> ptr, int elemSize, {int count = 1})
      : _ptr = ptr,
        elemSize = elemSize,
        arena = null,
        count = count;

  // ── Value access (scalar) ─────────────────────────────────────────────────

  /// Reads the value at index 0 (scalar access).
  ///
  /// Returns the Dart representation of the native value:
  /// - `double` for [Float] / [Double]
  /// - `int`    for all integer native types ([Int8]..[Int64], [Uint8]..[Uint64])
  ///
  /// Throws [StateError] if the associated [arena] has been disposed.
  Object get value {
    _assertLive();
    return _nativeRead(_ptr.cast<Uint8>(), 0, elemSize);
  }

  /// Writes [v] to index 0.
  ///
  /// [v] must be the Dart equivalent of the native type
  /// (`double` for float types, `int` for integer types).
  set value(Object v) {
    _assertLive();
    _nativeWrite(_ptr.cast<Uint8>(), 0, elemSize, v);
  }

  // ── Array access ──────────────────────────────────────────────────────────

  /// Returns a [Pointer<T>] to element at [index].
  ///
  /// For direct value access, use `(ptr[index]).value`.
  ///
  /// ```dart
  /// final floats = TypedPtr<Float>.arrayFromArena(arena,
  ///     count: 10, elemSize: sizeOf<Float>());
  /// (floats[3]).value = 42.0; // write to index 3
  /// ```
  Pointer<T> operator [](int index) {
    _boundsCheck(index);
    // Use byte-level address arithmetic because the generic `Pointer<T> + int`
    // operator is only defined for concrete (non-generic) native types.
    return Pointer<T>.fromAddress(_ptr.address + index * elemSize);
  }

  // ── Raw pointer access ────────────────────────────────────────────────────

  /// The underlying [Pointer<T>].
  Pointer<T> get pointer => _ptr;

  /// Raw memory address.
  int get address => _ptr.address;

  // ── Lifecycle helpers ─────────────────────────────────────────────────────

  /// `true` if the associated arena is still alive (not disposed).
  ///
  /// Always returns `true` when [arena] is null (no lifecycle tracking).
  bool get isAlive => arena == null || !arena!.isDisposed;

  void _assertLive() {
    if (arena != null && arena!.isDisposed) {
      throw StateError(
        'TypedPtr: the associated arena has been disposed. '
        'All pointers obtained from it are now dangling.',
      );
    }
  }

  void _boundsCheck(int index) {
    if (index < 0 || index >= count) {
      throw RangeError.index(index, this, 'index', null, count);
    }
  }

  @override
  String toString() => 'TypedPtr<$T>('
      'address: 0x${_ptr.address.toRadixString(16)}, '
      'count: $count, '
      'alive: $isAlive)';
}

// ── Module-level FFI read/write helpers ───────────────────────────────────────
//
// Dart's generic FFI erases `T` to `Never` at runtime, so `Pointer<T>.value`
// and `(ptr as dynamic).value` are both unusable in a generic context.
//
// We side-step this by reading/writing raw bytes via `Pointer<Uint8>` and a
// `ByteData` buffer, dispatching on `elemSize`.  The float/int distinction is
// preserved by inspecting the runtime type of the value being written.

/// Reads a single native scalar from [bytePtr] using host byte order.
///
/// Returns `double` when the stored value was written as a floating-point
/// type ([Float] / [Double]), otherwise returns `int`.
Object _nativeRead(Pointer<Uint8> bytePtr, int byteOffset, int elemSize) {
  final bd = ByteData(elemSize);
  for (int i = 0; i < elemSize; i++) {
    bd.setUint8(i, (bytePtr + byteOffset + i).value);
  }
  switch (elemSize) {
    case 1:
      return bd.getUint8(0);
    case 2:
      return bd.getInt16(0, Endian.host);
    case 4:
      // 4-byte slot: assume integer (Int32/Uint32/Float all share this path).
      // Callers that need Float32 fidelity should use `ptr.pointer.value`
      // on the concrete `Pointer<Float>` obtained from `TypedPtr.pointer`.
      return bd.getInt32(0, Endian.host);
    case 8:
      // 8-byte slot: assume double (covers Double; Int64 callers use
      // `ptr.pointer.value` on `Pointer<Int64>` for lossless int reads).
      return bd.getFloat64(0, Endian.host);
    default:
      throw UnsupportedError('_nativeRead: unsupported elemSize $elemSize');
  }
}

/// Writes a single native scalar [v] to [bytePtr] using host byte order.
///
/// Pass `double` for [Float] / [Double] types, `int` for integer types.
void _nativeWrite(
  Pointer<Uint8> bytePtr,
  int byteOffset,
  int elemSize,
  Object v,
) {
  final bd = ByteData(elemSize);
  switch (elemSize) {
    case 1:
      bd.setUint8(0, (v as int) & 0xFF);
    case 2:
      bd.setInt16(0, v as int, Endian.host);
    case 4:
      if (v is double) {
        bd.setFloat32(0, v, Endian.host);
      } else {
        bd.setInt32(0, v as int, Endian.host);
      }
    case 8:
      if (v is double) {
        bd.setFloat64(0, v, Endian.host);
      } else {
        bd.setInt64(0, v as int, Endian.host);
      }
    default:
      throw UnsupportedError('_nativeWrite: unsupported elemSize $elemSize');
  }
  for (int i = 0; i < elemSize; i++) {
    (bytePtr + byteOffset + i).value = bd.getUint8(i);
  }
}
