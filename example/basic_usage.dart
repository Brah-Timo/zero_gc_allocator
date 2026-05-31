/// Basic usage example for zero_gc_allocator.
///
/// Shows:
/// - Creating an arena
/// - Raw byte allocation
/// - Typed allocation
/// - Scoped regions (checkpoints)
/// - Arena reset and dispose
/// - Stats inspection
///
/// Run: dart run example/basic_usage.dart
library;

import 'dart:ffi';
import 'package:zero_gc_allocator/zero_gc_allocator.dart';

void main() {
  print('=== zero_gc_allocator — Basic Usage Demo ===\n');

  // ── 1. Create an arena (one syscall, GC-invisible forever) ────────────────
  final arena = ZeroGcArena(size: 16.mb);
  print('Created arena: $arena');
  print('Capacity: ${arena.capacity.toSizeString()}');
  print('Free: ${arena.remainingBytes.toSizeString()}\n');

  // ── 2. Raw byte allocation ────────────────────────────────────────────────
  print('--- Raw byte allocation ---');
  final rawPtr = arena.alloc(256, alignment: 8);
  rawPtr.fill(256, 0xAB); // fill with pattern
  print('Allocated 256 bytes at: ${rawPtr.toHexAddress()}');
  print('First byte: 0x${rawPtr.value.toRadixString(16).padLeft(2, '0')}');
  print('Is 8-byte aligned: ${rawPtr.isAlignedTo(8)}');
  print('Used bytes: ${arena.usedBytes.toSizeString()}\n');

  // ── 3. Typed allocation ───────────────────────────────────────────────────
  print('--- Typed allocation ---');

  // Allocate 1000 Float32 values (4 KB)
  final floats = arena.allocTyped<Float>(1000, elemSize: sizeOf<Float>());
  for (int i = 0; i < 1000; i++) {
    (floats + i).value = i * 0.001;
  }
  print('Allocated 1000 Float32 values');
  print('First: ${(floats + 0).value}');
  print('Last:  ${(floats + 999).value.toStringAsFixed(3)}');

  // Allocate an Int64 array
  final ids = arena.allocTyped<Int64>(100, elemSize: sizeOf<Int64>());
  for (int i = 0; i < 100; i++) {
    (ids + i).value = i * 1000000000;
  }
  print('Allocated 100 Int64 values');
  print('First: ${(ids + 0).value}');
  print('Last:  ${(ids + 99).value}\n');

  // ── 4. Scoped regions (checkpoints) ──────────────────────────────────────
  print('--- Scoped regions ---');

  final beforeScope = arena.usedBytes;
  print('Used before scope: ${beforeScope.toSizeString()}');

  final scope = arena.saveCheckpoint();
  final tempBuffer = arena.alloc(4.mb);
  tempBuffer.fill(4.mb, 0xFF);
  print('Used inside scope: ${arena.usedBytes.toSizeString()} (allocated 4MB temp)');

  // Restore — O(1), no GC
  arena.restoreCheckpoint(scope);
  print('Used after scope restore: ${arena.usedBytes.toSizeString()}');
  print('Bytes freed: ${(arena.usedBytes - beforeScope).abs().toSizeString()}\n');

  // ── 5. NativeBuffer ───────────────────────────────────────────────────────
  print('--- NativeBuffer (binary protocol) ---');
  final buf = NativeBuffer(arena: arena, size: 64);
  buf.appendUint32LE(0xDEADBEEF); // magic number
  buf.appendUint16LE(0x0100);      // version 1.0
  buf.appendUint8(0x42);           // command byte
  print('Buffer contents (hex):');
  print(buf.pointer.hexDump(7));
  print('Magic: 0x${buf.readUint32LE(0).toRadixString(16).toUpperCase()}');
  print('Version: 0x${buf.readUint16LE(4).toRadixString(16).padLeft(4, '0')}');
  print('Command: 0x${buf.readUint8(6).toRadixString(16).padLeft(2, '0')}\n');

  // ── 6. NativeString ───────────────────────────────────────────────────────
  print('--- NativeString ---');
  final greeting = NativeString.fromDart('Hello from zero_gc_allocator!', arena: arena);
  print('String: "${greeting.toDartString()}"');
  print('Bytes: ${greeting.byteLength}');

  final header = NativeString.concat(
    ['Content-Type: ', 'application/octet-stream', '\r\n'],
    arena: arena,
  );
  print('Concatenated: "${header.toDartString()}"\n');

  // ── 7. Stats ──────────────────────────────────────────────────────────────
  print('--- Arena statistics ---');
  print(arena.stats);

  // ── 8. Reset and reuse ────────────────────────────────────────────────────
  print('--- Reset (O(1)) ---');
  arena.reset();
  print('After reset: used=${arena.usedBytes}, isEmpty=${arena.isEmpty}');
  print('Arena resets: ${arena.stats.resetCount}');

  // ── 9. Dispose ────────────────────────────────────────────────────────────
  arena.dispose();
  print('\nArena disposed. isDisposed=${arena.isDisposed}');
  print('\n=== Demo complete ===');
}
