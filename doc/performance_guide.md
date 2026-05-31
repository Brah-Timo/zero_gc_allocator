# Performance Guide

## When to Use zero_gc_allocator

Use native allocation when:

- You have **large buffers** (> 1 MB) that would stress the GC.
- You **repeatedly create and discard** many small objects (high alloc rate).
- You need **deterministic latency** (e.g. game loops, HFT, audio processing).
- You process **binary data** from files, networks, or native libraries.

Use regular Dart allocation when:

- Objects are small and infrequently created.
- GC pauses are acceptable.
- Lifetimes are complex (native allocators do not support finalizers).

---

## Choosing the Right Allocator

| Pattern | Recommended Allocator |
|---------|-----------------------|
| Per-frame scratch | `BumpAllocator` + `reset()` each frame |
| Request-scoped objects | `ZeroGcArena` + `reset()` per request |
| Fixed-size pooled objects | `PoolAllocator` or `SlabAllocator` |
| Binary I/O buffers | `NativeBuffer` |
| Mix of sizes | `ZeroGcArena` |

---

## Benchmark Baselines (example, platform-dependent)

Run `dart run benchmark/gc_pause_comparison.dart` for live numbers.

| Benchmark | Typical throughput |
|-----------|--------------------|
| `NativeArena.allocInt32Array(10000)` | ~2× faster than GC list |
| `BumpAllocator.allocReset` | ~5× faster than `calloc` each time |
| `PoolAllocator.allocFree` | ~3× faster than `calloc`/`free` |
| `DartList.new(10000)` | Baseline for comparison |

> These numbers vary significantly by platform and Dart version.

---

## Tips

### 1. Prefer `ZeroGcArena` over `BumpAllocator` directly

`ZeroGcArena` automatically grows to new blocks when one is exhausted,
while `BumpAllocator` returns `nullptr`.

### 2. Size blocks appropriately

If you know you need ~4 MB per frame, pass `blockSize: 4 * 1024 * 1024` to
`ZeroGcArena`.  Over-small blocks cause repeated block allocation.

### 3. Reuse allocators across frames

```dart
final arena = ZeroGcArena(blockSize: 1024 * 1024);

void update() {
  arena.reset(); // O(1) — no OS call
  final buf = arena.allocDoubleArray(width * height);
  // ... render ...
}

void shutdown() => arena.dispose();
```

### 4. Prefer typed helpers over raw byte reads

`buf.readFloat64LE(offset)` is correct and readable.  Manual bit-shifting is
error-prone.

### 5. Avoid `toBytes()` in hot loops

`NativeBuffer.toBytes()` allocates a new `Uint8List` and copies all bytes.
In a hot path, read individual fields directly via `getUint8` / `readUint32LE`.

### 6. Align properly

Unaligned reads/writes may be slower or trap on some platforms.
Use `AlignmentUtils.alignUp` to ensure natural alignment.

---

## Memory Layout Optimisation

Pack frequently-accessed fields at the beginning of a struct to improve cache
line utilisation.  For 64-byte cache lines:

```
// Good — hot fields first
[price: 8][qty: 4][side: 4][id: 4][...padding...]

// Bad — hot field buried
[padding: 32][price: 8][qty: 4]...
```
