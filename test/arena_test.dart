// ignore_for_file: avoid_dynamic_calls
import 'dart:ffi';
import 'package:test/test.dart';
import 'package:zero_gc_allocator/zero_gc_allocator.dart';

void main() {
  group('ZeroGcArena — Construction', () {
    test('creates arena with valid positive size', () {
      final arena = ZeroGcArena(size: 1.mb);
      expect(arena.capacity, equals(1.mb));
      expect(arena.isDisposed, isFalse);
      expect(arena.isEmpty, isTrue);
      arena.dispose();
    });

    test('throws ArgumentError for non-positive size', () {
      expect(() => ZeroGcArena(size: 0), throwsArgumentError);
      expect(() => ZeroGcArena(size: -1), throwsArgumentError);
    });

    test('initial stats show zero usage', () {
      final arena = ZeroGcArena(size: 512.kb);
      expect(arena.stats.usedBytes, equals(0));
      expect(arena.stats.allocationCount, equals(0));
      expect(arena.stats.totalCapacity, equals(512.kb));
      arena.dispose();
    });
  });

  group('ZeroGcArena — alloc()', () {
    late ZeroGcArena arena;
    setUp(() => arena = ZeroGcArena(size: 4.mb));
    tearDown(() { if (!arena.isDisposed) arena.dispose(); });

    test('returns non-null pointer', () {
      final ptr = arena.alloc(256);
      expect(ptr.address, isNonZero);
    });

    test('returned memory is zero-initialized', () {
      final ptr = arena.alloc(128);
      for (int i = 0; i < 128; i++) {
        expect((ptr + i).value, equals(0),
            reason: 'Byte $i should be zero after alloc');
      }
    });

    test('sequential allocations are non-overlapping', () {
      final ptr1 = arena.alloc(100);
      final ptr2 = arena.alloc(100);
      // ptr2 must start at or after ptr1 + 100
      expect(ptr2.address - ptr1.address, greaterThanOrEqualTo(100));
    });

    test('usedBytes advances after allocation', () {
      expect(arena.usedBytes, equals(0));
      arena.alloc(512);
      expect(arena.usedBytes, greaterThanOrEqualTo(512));
    });

    test('alloc then write does not crash', () {
      final ptr = arena.alloc(64);
      for (int i = 0; i < 64; i++) {
        (ptr + i).value = i % 256;
      }
      for (int i = 0; i < 64; i++) {
        expect((ptr + i).value, equals(i % 256));
      }
    });

    test('throws ArgumentError for non-positive byteCount', () {
      expect(() => arena.alloc(0), throwsArgumentError);
      expect(() => arena.alloc(-1), throwsArgumentError);
    });

    test('throws ArenaOutOfMemoryException when capacity exceeded', () {
      expect(
        () => arena.alloc(8.mb), // bigger than 4.mb arena
        throwsA(isA<ArenaOutOfMemoryException>()),
      );
    });

    test('fills arena exactly to capacity without error', () {
      // alloc in two halves
      arena.alloc(2.mb - 8); // leave alignment room
      // one more reasonable alloc
      final remaining = arena.remainingBytes;
      if (remaining > 0) {
        arena.alloc(remaining);
      }
      expect(arena.isFull, isTrue);
    });
  });

  group('ZeroGcArena — allocTyped()', () {
    late ZeroGcArena arena;
    setUp(() => arena = ZeroGcArena(size: 1.mb));
    tearDown(() { if (!arena.isDisposed) arena.dispose(); });

    test('returns typed pointer for Float', () {
      final ptr = arena.allocTyped<Float>(10, elemSize: sizeOf<Float>());
      (ptr + 0).value = 3.14;
      expect((ptr + 0).value, closeTo(3.14, 0.001));
    });

    test('returns typed pointer for Int64', () {
      final ptr = arena.allocTyped<Int64>(5, elemSize: sizeOf<Int64>());
      (ptr + 0).value = -9223372036854775807;
      (ptr + 4).value = 9223372036854775807;
      expect((ptr + 0).value, equals(-9223372036854775807));
      expect((ptr + 4).value, equals(9223372036854775807));
    });

    test('allocates correct number of bytes', () {
      final before = arena.usedBytes;
      arena.allocTyped<Double>(128, elemSize: sizeOf<Double>());
      final after = arena.usedBytes;
      expect(after - before, greaterThanOrEqualTo(128 * 8)); // 8 bytes per Double
    });

    test('multiple typed arrays are independent', () {
      final a = arena.allocTyped<Int32>(4, elemSize: sizeOf<Int32>());
      final b = arena.allocTyped<Int32>(4, elemSize: sizeOf<Int32>());
      (a + 0).value = 111;
      (b + 0).value = 222;
      expect((a + 0).value, equals(111));
      expect((b + 0).value, equals(222));
    });
  });

  group('ZeroGcArena — allocUninit()', () {
    late ZeroGcArena arena;
    setUp(() => arena = ZeroGcArena(size: 1.mb));
    tearDown(() { if (!arena.isDisposed) arena.dispose(); });

    test('returns valid pointer', () {
      final ptr = arena.allocUninit(128);
      expect(ptr.address, isNonZero);
      // Write and read back
      (ptr + 0).value = 0xFE;
      expect((ptr + 0).value, equals(0xFE));
    });

    test('advances usedBytes', () {
      final before = arena.usedBytes;
      arena.allocUninit(256);
      expect(arena.usedBytes, greaterThan(before));
    });
  });

  group('ZeroGcArena — Alignment', () {
    late ZeroGcArena arena;
    setUp(() => arena = ZeroGcArena(size: 2.mb));
    tearDown(() => arena.dispose());

    test('default alignment: pointer is 8-byte aligned', () {
      arena.alloc(1); // intentionally misalign cursor
      final ptr = arena.alloc(8);
      expect(ptr.address % 8, equals(0),
          reason: 'Default alignment must be 8 bytes');
    });

    test('explicit 16-byte alignment', () {
      final ptr = arena.alloc(32, alignment: 16);
      expect(ptr.address % 16, equals(0));
    });

    test('explicit 64-byte alignment (cache-line)', () {
      arena.alloc(1); // force misalignment
      final ptr = arena.alloc(64, alignment: 64);
      expect(ptr.address % 64, equals(0));
    });

    test('throws ArgumentError for non-power-of-two alignment', () {
      expect(() => arena.alloc(8, alignment: 3), throwsArgumentError);
      expect(() => arena.alloc(8, alignment: 6), throwsArgumentError);
      expect(() => arena.alloc(8, alignment: 0), throwsArgumentError);
    });

    test('multiple allocs with different alignments all correct', () {
      final p1 = arena.alloc(1, alignment: 1);
      final p2 = arena.alloc(4, alignment: 4);
      final p4 = arena.alloc(16, alignment: 16);
      final p8 = arena.alloc(32, alignment: 32);
      expect(p1.address % 1, equals(0));
      expect(p2.address % 4, equals(0));
      expect(p4.address % 16, equals(0));
      expect(p8.address % 32, equals(0));
    });
  });

  group('ZeroGcArena — reset()', () {
    late ZeroGcArena arena;
    setUp(() => arena = ZeroGcArena(size: 1.mb));
    tearDown(() { if (!arena.isDisposed) arena.dispose(); });

    test('reset() rewinds usedBytes to 0', () {
      arena.alloc(256.kb);
      arena.reset();
      expect(arena.usedBytes, equals(0));
      expect(arena.isEmpty, isTrue);
    });

    test('after reset(), arena can be fully reused', () {
      arena.alloc(512.kb);
      arena.reset();
      expect(() => arena.alloc(512.kb), returnsNormally);
    });

    test('reset increments resetCount in stats', () {
      arena.alloc(1024);
      arena.reset();
      arena.alloc(1024);
      arena.reset();
      expect(arena.stats.resetCount, equals(2));
    });

    test('reset(zeroMemory: true) zeroes the used region', () {
      final ptr = arena.alloc(64);
      for (int i = 0; i < 64; i++) (ptr + i).value = 0xFF;
      arena.reset(zeroMemory: true);
      // After reset, allocate again at same location
      final ptr2 = arena.alloc(64);
      for (int i = 0; i < 64; i++) {
        expect((ptr2 + i).value, equals(0),
            reason: 'zeroMemory should have cleared byte $i');
      }
    });

    test('reset(zeroMemory: false) does not guarantee zero bytes', () {
      // This test just verifies no exception is thrown
      arena.alloc(64);
      expect(() => arena.reset(zeroMemory: false), returnsNormally);
    });
  });

  group('ZeroGcArena — dispose()', () {
    test('dispose() marks arena as disposed', () {
      final arena = ZeroGcArena(size: 64.kb);
      arena.dispose();
      expect(arena.isDisposed, isTrue);
    });

    test('double dispose() throws ArenaDisposedException', () {
      final arena = ZeroGcArena(size: 64.kb);
      arena.dispose();
      expect(() => arena.dispose(), throwsA(isA<ArenaDisposedException>()));
    });

    test('alloc after dispose throws ArenaDisposedException', () {
      final arena = ZeroGcArena(size: 64.kb);
      arena.dispose();
      expect(() => arena.alloc(64), throwsA(isA<ArenaDisposedException>()));
    });

    test('reset after dispose throws ArenaDisposedException', () {
      final arena = ZeroGcArena(size: 64.kb);
      arena.dispose();
      expect(() => arena.reset(), throwsA(isA<ArenaDisposedException>()));
    });
  });

  group('ZeroGcArena — Checkpoints / Regions', () {
    late ZeroGcArena arena;
    setUp(() => arena = ZeroGcArena(size: 1.mb));
    tearDown(() { if (!arena.isDisposed) arena.dispose(); });

    test('saveCheckpoint captures current offset', () {
      arena.alloc(1024);
      final offset = arena.usedBytes;
      final region = arena.saveCheckpoint();
      expect(region.offsetAtCreation, equals(offset));
    });

    test('restoreCheckpoint rewinds cursor', () {
      final before = arena.usedBytes;
      final region = arena.saveCheckpoint();
      arena.alloc(4096);
      expect(arena.usedBytes, greaterThan(before));
      arena.restoreCheckpoint(region);
      expect(arena.usedBytes, equals(before));
    });

    test('region.restore() is equivalent to arena.restoreCheckpoint(region)', () {
      final region = arena.saveCheckpoint();
      arena.alloc(2048);
      region.restore();
      expect(arena.usedBytes, equals(region.offsetAtCreation));
    });

    test('double restore throws ArenaRegionException', () {
      final region = arena.saveCheckpoint();
      arena.alloc(512);
      region.restore();
      expect(() => region.restore(), throwsA(isA<ArenaRegionException>()));
    });

    test('restoring region from different arena throws ArenaRegionException', () {
      final other = ZeroGcArena(size: 64.kb);
      final region = other.saveCheckpoint();
      expect(
        () => arena.restoreCheckpoint(region),
        throwsA(isA<ArenaRegionException>()),
      );
      other.dispose();
    });

    test('nested checkpoints restore in LIFO order correctly', () {
      final r1 = arena.saveCheckpoint();  // offset = 0
      arena.alloc(128);
      final r2 = arena.saveCheckpoint();  // offset ≈ 128
      arena.alloc(256);
      final r3 = arena.saveCheckpoint();  // offset ≈ 384
      arena.alloc(512);

      arena.restoreCheckpoint(r3);
      expect(arena.usedBytes, equals(r3.offsetAtCreation));

      arena.restoreCheckpoint(r2);
      expect(arena.usedBytes, equals(r2.offsetAtCreation));

      arena.restoreCheckpoint(r1);
      expect(arena.usedBytes, equals(r1.offsetAtCreation));
      expect(arena.isEmpty, isTrue);
    });

    test('region.bytesAllocated returns correct count', () {
      final region = arena.saveCheckpoint();
      arena.alloc(100, alignment: 1);
      // bytesAllocated should be at least 100
      expect(region.bytesAllocated, greaterThanOrEqualTo(100));
    });
  });

  group('ZeroGcArena — ArenaStats', () {
    late ZeroGcArena arena;
    setUp(() => arena = ZeroGcArena(size: 1.mb));
    tearDown(() { if (!arena.isDisposed) arena.dispose(); });

    test('allocationCount increments on every alloc call', () {
      expect(arena.stats.allocationCount, equals(0));
      arena.alloc(64);
      arena.alloc(128);
      arena.allocTyped<Float>(10, elemSize: sizeOf<Float>());
      expect(arena.stats.allocationCount, equals(3));
    });

    test('peakUsage tracks highest usedBytes', () {
      arena.alloc(512.kb);
      final peak1 = arena.stats.peakUsage;
      arena.reset();
      arena.alloc(128.kb);
      // Peak should not have decreased
      expect(arena.stats.peakUsage, equals(peak1));
    });

    test('snapshot() is immutable', () {
      arena.alloc(256);
      final snap = arena.stats.snapshot();
      arena.alloc(256);
      expect(snap.usedBytes, lessThan(arena.stats.usedBytes));
    });

    test('snapshot delta works correctly', () {
      final before = arena.stats.snapshot();
      arena.alloc(100, alignment: 1);
      arena.alloc(100, alignment: 1);
      final after = arena.stats.snapshot();
      final delta = after.delta(before);
      expect(delta.allocCalls, equals(2));
      expect(delta.bytesAllocated, greaterThanOrEqualTo(200));
    });
  });
}
