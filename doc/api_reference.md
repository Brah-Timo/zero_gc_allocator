# API Reference

## ZeroGcArena

A region-based allocator.  All allocations are freed together on `dispose` or
`reset`.

```
ZeroGcArena({int blockSize = 1048576})
```

### Properties

| Property | Type | Description |
|----------|------|-------------|
| `stats` | `ArenaStats` | Cumulative allocation statistics |
| `isDisposed` | `bool` | True after `dispose()` is called |

### Methods

| Method | Returns | Description |
|--------|---------|-------------|
| `allocRaw(int bytes, {int alignment})` | `Pointer<Uint8>` | Allocate raw bytes |
| `allocInt32()` | `Pointer<Int32>` | Allocate one `Int32` |
| `allocInt32Array(int count)` | `Pointer<Int32>` | Allocate array of `Int32` |
| `allocInt64()` | `Pointer<Int64>` | Allocate one `Int64` |
| `allocInt64Array(int count)` | `Pointer<Int64>` | Allocate array of `Int64` |
| `allocDouble()` | `Pointer<Double>` | Allocate one `Double` |
| `allocDoubleArray(int count)` | `Pointer<Double>` | Allocate array of `Double` |
| `allocFloat()` | `Pointer<Float>` | Allocate one `Float` |
| `allocFloatArray(int count)` | `Pointer<Float>` | Allocate array of `Float` |
| `allocElements(int count, int elemSize)` | `Pointer<Uint8>` | Generic byte allocation |
| `reset()` | `void` | Reset bump cursor; invalidate all allocations |
| `dispose()` | `void` | Free all native memory |

---

## BumpAllocator

Linear bump-pointer allocator.  Fastest allocation; no individual free.

```
BumpAllocator(int capacity)
```

### Properties

| Property | Type | Description |
|----------|------|-------------|
| `capacity` | `int` | Total bytes |
| `used` | `int` | Bytes consumed |
| `remaining` | `int` | Bytes left |

### Methods

| Method | Returns | Description |
|--------|---------|-------------|
| `allocBytes(int bytes, {int alignment})` | `Pointer<Uint8>` | Raw bytes |
| `allocElements(int count, int elemSize, {int alignment})` | `Pointer<Uint8>` | Typed elements |
| `allocInt32()` / `allocInt32Array(n)` | `Pointer<Int32>` | Int32 helpers |
| `allocInt64()` / `allocInt64Array(n)` | `Pointer<Int64>` | Int64 helpers |
| `allocDouble()` / `allocDoubleArray(n)` | `Pointer<Double>` | Double helpers |
| `allocFloat()` / `allocFloatArray(n)` | `Pointer<Float>` | Float helpers |
| `reset()` | `void` | Reset cursor to zero |
| `dispose()` | `void` | Free backing memory |

---

## PoolAllocator

Fixed-size slot pool with O(1) alloc and free.

```
PoolAllocator({required int slotSize, required int capacity})
```

### Properties

| Property | Type | Description |
|----------|------|-------------|
| `slotSize` | `int` | Bytes per slot |
| `capacity` | `int` | Total slots |
| `available` | `int` | Free slots |
| `inUse` | `int` | Occupied slots |

### Methods

| Method | Returns | Description |
|--------|---------|-------------|
| `alloc()` | `Pointer<Uint8>` | Allocate one slot; `nullptr` if full |
| `free(Pointer<Uint8>)` | `void` | Return slot to pool |
| `reset()` | `void` | Mark all slots free |
| `dispose()` | `void` | Free native memory |

---

## SlabAllocator

Slab allocator with typed slots and free-list.

```
SlabAllocator({required int slotSize, required int capacity})
```

### Methods

| Method | Returns | Description |
|--------|---------|-------------|
| `alloc()` | `Pointer<Uint8>` | Allocate one slot |
| `free(Pointer<Uint8>)` | `void` | Return slot |
| `owns(Pointer<Uint8>)` | `bool` | Test ownership |
| `reset()` | `void` | Reset free list |
| `dispose()` | `void` | Free memory |

---

## NativeBuffer

Byte buffer backed by native memory with typed read/write helpers.

```
NativeBuffer(int size)
NativeBuffer.fromPointer(Pointer<Uint8> ptr, int size)
```

### Properties

| Property | Type | Description |
|----------|------|-------------|
| `size` | `int` | Buffer size in bytes |
| `pointer` | `Pointer<Uint8>` | Raw pointer |

### Read/Write Methods

| Method | Description |
|--------|-------------|
| `getUint8(int offset)` / `setUint8(int offset, int value)` | Byte access |
| `readUint16LE(int offset)` / `writeUint16LE(int offset, int value)` | LE uint16 |
| `readUint32LE(int offset)` / `writeUint32LE(int offset, int value)` | LE uint32 |
| `readUint64LE(int offset)` / `writeUint64LE(int offset, int value)` | LE uint64 |
| `readFloat32LE(int offset)` / `writeFloat32LE(int offset, double value)` | LE float32 |
| `readFloat64LE(int offset)` / `writeFloat64LE(int offset, double value)` | LE float64 |
| `readUint16BE` / `writeUint16BE` | BE uint16 |
| `readUint32BE` / `writeUint32BE` | BE uint32 |
| `copyFrom(NativeBuffer, int, int, int)` | Copy bytes |
| `toBytes()` | `Uint8List` snapshot |
| `dispose()` | Free memory (if owned) |

---

## TypedPtr\<T\>

A generic pointer wrapper that provides type-safe value access via static
factory constructors.

```dart
// Static factories (concrete type required at call site)
TypedPtr.int32(Pointer<Int32> ptr)
TypedPtr.int64(Pointer<Int64> ptr)
TypedPtr.double64(Pointer<Double> ptr)
TypedPtr.float(Pointer<Float> ptr)
TypedPtr.uint8(Pointer<Uint8> ptr)
```

### Properties

| Property | Type | Description |
|----------|------|-------------|
| `doubleValue` | `double` (get/set) | For `TypedPtr<Double>` |
| `floatValue` | `double` (get/set) | For `TypedPtr<Float>` |
| `int32Value` | `int` (get/set) | For `TypedPtr<Int32>` |
| `int64Value` | `int` (get/set) | For `TypedPtr<Int64>` |
| `uint8Value` | `int` (get/set) | For `TypedPtr<Uint8>` |
| `rawPointer` | `Pointer<Uint8>` | Underlying byte pointer |
| `elementSize` | `int` | Bytes per element |

### Methods

| Method | Returns | Description |
|--------|---------|-------------|
| `elementAt(int index)` | `TypedPtr<T>` | Advance by [index] elements |
| `toByteData()` | `ByteData` | Byte view of current element |

---

## NativeList typed sub-classes

All sub-classes expose `[]` and `[]=` operators plus `slice(start, count)`.

| Class | Element type | Element size |
|-------|-------------|--------------|
| `NativeInt32List` | `Int32` | 4 bytes |
| `NativeInt64List` | `Int64` | 8 bytes |
| `NativeFloat32List` | `Float` | 4 bytes |
| `NativeFloat64List` | `Double` | 8 bytes |
| `NativeUint8List` | `Uint8` | 1 byte |

Constructors: `NativeXxxList(int length)`.

---

## AlignmentUtils

| Method | Description |
|--------|-------------|
| `alignUp(int size, int alignment)` | Round up to alignment |
| `alignDown(int size, int alignment)` | Round down to alignment |
| `isAligned(int address, int alignment)` | Test alignment |
| `naturalAlignmentForSize(int size)` | Platform-natural alignment |
| `naturalAlignmentFor<T>()` | Alignment for concrete FFI type |
| `paddingFor(int offset, int alignment)` | Padding bytes needed |
| `pageAlignUp(int bytes)` | Round up to OS page size |

---

## MemoryGuard

Canary-word buffer overrun detector.

```
MemoryGuard(int size)
```

| Method | Description |
|--------|-------------|
| `check()` | Returns `true` if both canaries are intact |
| `dataPointer` | `Pointer<Uint8>` to the usable region |
| `dispose()` | Free native memory |
