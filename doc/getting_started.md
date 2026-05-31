# Getting Started with zero_gc_allocator

`zero_gc_allocator` provides off-heap native memory allocation strategies for
Dart/Flutter, backed by `dart:ffi`.  Memory is invisible to the Dart GC,
eliminating GC pauses from large or high-frequency heap allocations.

---

## Requirements

| Requirement | Minimum |
|-------------|---------|
| Dart SDK    | 3.6.0   |
| Flutter SDK | 3.10.0  |
| ffi package | 2.1.0   |

---

## Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  zero_gc_allocator: ^0.1.0
  ffi: ^2.1.0
```

Then run:

```bash
flutter pub get
```

---

## Quick Start

### Arena Allocator (recommended for most use cases)

```dart
import 'package:zero_gc_allocator/zero_gc_allocator.dart';

void main() {
  // Create a 1 MiB arena
  final arena = ZeroGcArena(blockSize: 1024 * 1024);

  // Allocate a single Int32
  final ptr = arena.allocInt32();
  ptr.value = 42;
  print(ptr.value); // 42

  // Allocate an array of 1000 Float64 values
  final doubles = arena.allocDoubleArray(1000);
  for (var i = 0; i < 1000; i++) {
    doubles.elementAt(i).value = i * 0.1;
  }

  // Reset reuses backing memory without OS round-trips
  arena.reset();

  // Free all native memory
  arena.dispose();
}
```

### Bump Allocator (fastest, no individual free)

```dart
final bump = BumpAllocator(65536); // 64 KiB

final ptr = bump.allocInt32Array(100);
ptr.elementAt(0).value = 99;

// Reset — all previous pointers are invalidated
bump.reset();

bump.dispose();
```

### Pool Allocator (fixed-size, O(1) alloc + free)

```dart
final pool = PoolAllocator(slotSize: 64, capacity: 512);

final slot = pool.alloc();
// ... use slot ...
pool.free(slot);

pool.dispose();
```

### Native Buffer (structured byte access)

```dart
final buf = NativeBuffer(16);

buf.writeUint32LE(0, 0xDEADBEEF);
print(buf.readUint32LE(0).toRadixString(16)); // deadbeef

buf.writeFloat64LE(8, 3.14159);
print(buf.readFloat64LE(8)); // 3.14159

buf.dispose();
```

---

## Memory Ownership Rules

| Class | Who frees memory? |
|-------|-------------------|
| `NativeBuffer(size)` | `dispose()` on the buffer |
| `NativeBuffer.fromPointer(ptr, size)` | Caller is responsible |
| `ZeroGcArena` | `dispose()` on the arena |
| `BumpAllocator` | `dispose()` on the allocator |
| `PoolAllocator` | `dispose()` on the pool |

> **Important**: Always call `dispose()` when you are done — native memory is
> not released automatically by the Dart GC.

---

## Next Steps

- [API Reference](api_reference.md)
- [Architecture Guide](architecture.md)
- [Performance Guide](performance_guide.md)
