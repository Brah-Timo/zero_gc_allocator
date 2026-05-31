import 'dart:ffi';
import 'dart:isolate';
import 'package:test/test.dart';
import 'package:zero_gc_allocator/zero_gc_allocator.dart';

/// Isolate-based concurrency tests.
///
/// These tests verify that:
/// 1. Each isolate can independently manage its own [ZeroGcArena].
/// 2. Native pointer addresses (as `int`) can be safely communicated
///    between isolates via [SendPort].
/// 3. Multiple isolates do not interfere with each other's allocations.
void main() {
  group('Isolate independence', () {
    test('two isolates each create their own arena (no crash)', () async {
      final result1 = await Isolate.run(() => _isolateWork(1.mb, 10000));
      final result2 = await Isolate.run(() => _isolateWork(2.mb, 20000));
      expect(result1, equals('ok:10000'));
      expect(result2, equals('ok:20000'));
    });

    test('50 isolates run concurrently without interference', () async {
      final futures = List.generate(
        50,
        (i) => Isolate.run(() => _isolateWork(256.kb, 1000)),
      );
      final results = await Future.wait(futures);
      for (final r in results) {
        expect(r, equals('ok:1000'));
      }
    }, timeout: const Timeout(Duration(seconds: 30)));
  });

  group('Pointer address communication across isolates', () {
    test('can communicate native address as int between isolates', () async {
      // Allocate in parent, pass address to child, child writes, parent reads
      final arena = ZeroGcArena(size: 64.kb);
      final ptr = arena.alloc(8);

      // Write address to child isolate, child writes a known value
      final addr = ptr.address;
      final wroteValue = await Isolate.run(() => _writeToAddress(addr, 0xDEAD));
      expect(wroteValue, isTrue);

      // Read the value back in parent
      final readBack = Pointer<Uint16>.fromAddress(addr).value;
      expect(readBack, equals(0xDEAD));

      arena.dispose();
    });
  });

  group('ZeroGcPool isolate safety', () {
    test('pool operations work correctly in an isolate', () async {
      final result = await Isolate.run(() {
        final pool = ZeroGcPool(blockSize: 64, capacity: 500);
        final ptrs = <int>[];
        for (int i = 0; i < 500; i++) {
          ptrs.add(pool.alloc().address);
        }
        for (final addr in ptrs) {
          pool.free(Pointer<Uint8>.fromAddress(addr));
        }
        final freeCount = pool.freeSlots;
        pool.dispose();
        return freeCount;
      });
      expect(result, equals(500));
    });
  });

  group('Arena reuse stress', () {
    test('1000 reset cycles in isolate are stable', () async {
      final result = await Isolate.run(() {
        final arena = ZeroGcArena(size: 1.mb);
        int totalAllocs = 0;
        for (int cycle = 0; cycle < 1000; cycle++) {
          for (int j = 0; j < 10; j++) {
            arena.alloc(1024, alignment: 8);
            totalAllocs++;
          }
          arena.reset();
        }
        arena.dispose();
        return totalAllocs;
      });
      expect(result, equals(10000));
    });
  });
}

// ── Worker functions (run inside Isolate.run) ─────────────────────────────

String _isolateWork(int size, int allocCount) {
  final arena = ZeroGcArena(size: size);
  for (int i = 0; i < allocCount; i++) {
    final ptr = arena.alloc(8, alignment: 8);
    (ptr + 0).value = i % 256;
  }
  arena.reset();
  arena.dispose();
  return 'ok:$allocCount';
}

bool _writeToAddress(int address, int value) {
  try {
    Pointer<Uint16>.fromAddress(address).value = value;
    return true;
  } catch (_) {
    return false;
  }
}
