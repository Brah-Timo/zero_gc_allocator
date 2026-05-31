import 'dart:ffi';
import 'package:test/test.dart';
import 'package:zero_gc_allocator/zero_gc_allocator.dart';

/// Memory safety invariant tests.
///
/// These tests verify that the allocators correctly enforce lifetime rules
/// and boundary conditions, providing meaningful error messages rather
/// than silent crashes or undefined behavior.
void main() {
  group('MemoryGuard — overflow detection', () {
    late MemoryGuard guard;

    setUp(() => guard = MemoryGuard(
          ZeroGcArena(size: 1.mb),
          guardSize: 16,
          canaryByte: 0xCD,
        ));
    tearDown(() { if (!guard.arena.isDisposed) guard.dispose(); });

    test('verify() passes when no overflow occurs', () {
      final ptr = guard.alloc(64);
      // Only write within the 64-byte allocation
      for (int i = 0; i < 64; i++) (ptr + i).value = 0xAA;
      expect(() => guard.verify(), returnsNormally);
    });

    test('verify() detects 1-byte overflow', () {
      final ptr = guard.alloc(64);
      // Write one byte beyond the 64-byte boundary
      (ptr + 64).value = 0xFF; // this is in the guard region
      expect(() => guard.verify(), throwsA(isA<MemoryOverflowDetected>()));
    });

    test('MemoryOverflowDetected contains useful diagnostic info', () {
      final ptr = guard.alloc(64);
      (ptr + 64).value = 0xDE;
      try {
        guard.verify();
        fail('Expected MemoryOverflowDetected');
      } on MemoryOverflowDetected catch (e) {
        expect(e.userSize, equals(64));
        expect(e.byteOffset, equals(0));
        expect(e.expectedByte, equals(0xCD));
        expect(e.actualByte, equals(0xDE));
        final msg = e.toString();
        expect(msg, contains('MemoryOverflowDetected'));
        expect(msg, contains('64'));
      }
    });

    test('isIntact() returns true when clean', () {
      guard.alloc(32);
      expect(guard.isIntact(), isTrue);
    });

    test('isIntact() returns false after overflow', () {
      final ptr = guard.alloc(32);
      (ptr + 32).value = 0x01; // corrupt guard
      expect(guard.isIntact(), isFalse);
    });

    test('allocationCount tracks all alloc calls', () {
      guard.alloc(10, alignment: 1);
      guard.alloc(20, alignment: 1);
      guard.alloc(30, alignment: 1);
      expect(guard.allocationCount, equals(3));
    });

    test('reset() clears guard list', () {
      guard.alloc(64);
      guard.alloc(128);
      guard.reset();
      expect(guard.allocationCount, equals(0));
    });

    test('multiple guards all verified', () {
      for (int i = 0; i < 10; i++) {
        final ptr = guard.alloc(32, alignment: 1);
        // Write exactly 32 bytes (no overflow)
        for (int j = 0; j < 32; j++) (ptr + j).value = j;
      }
      final count = guard.verify();
      expect(count, equals(10));
    });
  });

  group('ArenaOutOfMemoryException — diagnostic quality', () {
    test('exception message contains requested/available/total', () {
      final arena = ZeroGcArena(size: 256.kb);
      arena.alloc(200.kb);
      try {
        arena.alloc(100.kb); // will fail
        fail('Expected ArenaOutOfMemoryException');
      } on ArenaOutOfMemoryException catch (e) {
        final msg = e.toString();
        expect(msg, contains('ArenaOutOfMemoryException'));
        expect(msg, contains('ZeroGcArena'));
        expect(msg, contains('Tip:'));
        // Usage bar
        expect(msg, contains('█'));
        arena.dispose();
      }
    });

    test('exception usageRatio is between 0 and 1', () {
      final arena = ZeroGcArena(size: 256.kb);
      arena.alloc(200.kb);
      try {
        arena.alloc(100.kb);
      } on ArenaOutOfMemoryException catch (e) {
        expect(e.usageRatio, greaterThan(0));
        expect(e.usageRatio, lessThanOrEqualTo(1.0));
        arena.dispose();
      }
    });
  });

  group('Dispose-then-use invariants', () {
    test('ZeroGcArena: alloc after dispose throws', () {
      final a = ZeroGcArena(size: 64.kb);
      a.dispose();
      expect(() => a.alloc(8), throwsA(isA<ArenaDisposedException>()));
    });

    test('ZeroGcArena: reset after dispose throws', () {
      final a = ZeroGcArena(size: 64.kb);
      a.dispose();
      expect(() => a.reset(), throwsA(isA<ArenaDisposedException>()));
    });

    test('ZeroGcArena: saveCheckpoint after dispose throws', () {
      final a = ZeroGcArena(size: 64.kb);
      a.dispose();
      expect(() => a.saveCheckpoint(), throwsA(isA<ArenaDisposedException>()));
    });

    test('ZeroGcPool: alloc after dispose throws', () {
      final p = ZeroGcPool(blockSize: 64, capacity: 10);
      p.dispose();
      expect(() => p.alloc(), throwsA(isA<ArenaDisposedException>()));
    });

    test('ZeroGcPool: free after dispose throws', () {
      final p = ZeroGcPool(blockSize: 64, capacity: 10);
      final ptr = p.alloc();
      p.dispose();
      expect(() => p.free(ptr), throwsA(isA<ArenaDisposedException>()));
    });

    test('ZeroGcSlab: alloc after dispose throws', () {
      final s = ZeroGcSlab<Int64>(
          elementCount: 10, stride: 1, elemSize: sizeOf<Int64>());
      s.dispose();
      expect(() => s.alloc(), throwsA(isA<ArenaDisposedException>()));
    });

    test('BumpAllocator: allocate after dispose throws', () {
      final b = BumpAllocator(capacity: 64.kb);
      b.dispose();
      expect(() => b.allocate(64), throwsA(isA<ArenaDisposedException>()));
    });
  });

  group('AlignmentException', () {
    test('constructor stores alignment and reason', () {
      const ex = AlignmentException(alignment: 3, reason: 'not a power of two');
      expect(ex.alignment, equals(3));
      expect(ex.reason, contains('not a power of two'));
      final msg = ex.toString();
      expect(msg, contains('AlignmentException'));
      expect(msg, contains('3'));
    });
  });

  group('ArenaRegionException', () {
    test('message is preserved', () {
      const ex = ArenaRegionException('test message');
      expect(ex.message, equals('test message'));
      expect(ex.toString(), contains('ArenaRegionException'));
      expect(ex.toString(), contains('test message'));
    });
  });

  group('NativeBuffer — safety', () {
    late ZeroGcArena arena;
    setUp(() => arena = ZeroGcArena(size: 256.kb));
    tearDown(() { if (!arena.isDisposed) arena.dispose(); });

    test('out-of-bounds readUint8 throws RangeError', () {
      final buf = NativeBuffer(arena: arena, size: 16);
      expect(() => buf.readUint8(16), throwsRangeError);
      expect(() => buf.readUint8(-1), throwsRangeError);
    });

    test('out-of-bounds writeUint32 throws RangeError', () {
      final buf = NativeBuffer(arena: arena, size: 16);
      expect(() => buf.writeUint32LE(14, 0xDEAD), throwsRangeError); // needs 4 bytes at 14 → 18 > 16
    });

    test('writeBytes beyond size throws RangeError', () {
      final buf = NativeBuffer(arena: arena, size: 8);
      expect(
        () => buf.writeBytes(6, [1, 2, 3, 4, 5]), // 6+5 = 11 > 8
        throwsRangeError,
      );
    });
  });

  group('NativeList — safety', () {
    late ZeroGcArena arena;
    setUp(() => arena = ZeroGcArena(size: 128.kb));
    tearDown(() { if (!arena.isDisposed) arena.dispose(); });

    test('negative length throws ArgumentError', () {
      expect(() => NativeList<Int32>(arena: arena, length: -1,
          elemSize: sizeOf<Int32>()), throwsArgumentError);
      expect(() => NativeList<Int32>(arena: arena, length: 0,
          elemSize: sizeOf<Int32>()), throwsArgumentError);
    });

    test('out-of-bounds access throws RangeError', () {
      final list = NativeList<Float>(arena: arena, length: 5,
          elemSize: sizeOf<Float>());
      expect(() => list[-1], throwsRangeError);
      expect(() => list[5], throwsRangeError);
    });

    test('subList out-of-bounds throws RangeError', () {
      final list = NativeList<Int32>(arena: arena, length: 10,
          elemSize: sizeOf<Int32>());
      expect(() => list.subList(8, 5), throwsRangeError); // 8+5=13 > 10
    });
  });
}
