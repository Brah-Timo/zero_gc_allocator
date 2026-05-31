import 'dart:ffi';
import 'package:test/test.dart';
import 'package:zero_gc_allocator/zero_gc_allocator.dart';

void main() {
  // ── ZeroGcPool tests ────────────────────────────────────────────────────

  group('ZeroGcPool — Construction', () {
    test('creates pool with valid parameters', () {
      final pool = ZeroGcPool(blockSize: 64, capacity: 100);
      expect(pool.capacity, equals(100));
      expect(pool.blockSize, greaterThanOrEqualTo(64)); // may be padded
      expect(pool.usedSlots, equals(0));
      expect(pool.freeSlots, equals(100));
      pool.dispose();
    });

    test('blockSize is rounded up to 8-byte multiple', () {
      final pool = ZeroGcPool(blockSize: 9, capacity: 10);
      expect(pool.blockSize % 8, equals(0),
          reason: 'blockSize should be aligned to 8 bytes');
      pool.dispose();
    });

    test('throws ArgumentError for capacity <= 0', () {
      expect(() => ZeroGcPool(blockSize: 64, capacity: 0), throwsArgumentError);
      expect(() => ZeroGcPool(blockSize: 64, capacity: -1), throwsArgumentError);
    });
  });

  group('ZeroGcPool — alloc()', () {
    late ZeroGcPool pool;
    setUp(() => pool = ZeroGcPool(blockSize: 64, capacity: 50));
    tearDown(() => pool.dispose());

    test('alloc returns valid non-null pointer', () {
      final ptr = pool.alloc();
      expect(ptr.address, isNonZero);
    });

    test('alloc returns zero-initialized slot', () {
      final ptr = pool.alloc();
      for (int i = 0; i < 64; i++) {
        expect((ptr + i).value, equals(0),
            reason: 'Slot byte $i should be zero');
      }
    });

    test('usedSlots increments on alloc', () {
      expect(pool.usedSlots, equals(0));
      pool.alloc();
      pool.alloc();
      pool.alloc();
      expect(pool.usedSlots, equals(3));
      expect(pool.freeSlots, equals(47));
    });

    test('can allocate up to capacity', () {
      for (int i = 0; i < 50; i++) {
        expect(() => pool.alloc(), returnsNormally);
      }
      expect(pool.isFull, isTrue);
      expect(pool.freeSlots, equals(0));
    });

    test('throws ArenaOutOfMemoryException when exhausted', () {
      for (int i = 0; i < 50; i++) pool.alloc();
      expect(() => pool.alloc(), throwsA(isA<ArenaOutOfMemoryException>()));
    });

    test('allocated pointers are within pool bounds', () {
      final base = pool.alloc().address;
      pool.free(Pointer<Uint8>.fromAddress(base));
      // Can re-alloc
      final ptr2 = pool.alloc();
      expect(ptr2.address, equals(base)); // LIFO free-list
    });
  });

  group('ZeroGcPool — free()', () {
    late ZeroGcPool pool;
    setUp(() => pool = ZeroGcPool(blockSize: 64, capacity: 10));
    tearDown(() => pool.dispose());

    test('free decrements usedSlots', () {
      final p = pool.alloc();
      expect(pool.usedSlots, equals(1));
      pool.free(p);
      expect(pool.usedSlots, equals(0));
    });

    test('freed slot can be reallocated', () {
      final p1 = pool.alloc();
      final addr = p1.address;
      pool.free(p1);
      final p2 = pool.alloc();
      expect(p2.address, equals(addr)); // LIFO reuse
    });

    test('alloc/free cycle 1000 times on 10-slot pool', () {
      for (int cycle = 0; cycle < 1000; cycle++) {
        final ptrs = List.generate(10, (_) => pool.alloc());
        for (final p in ptrs) pool.free(p);
        expect(pool.usedSlots, equals(0));
        expect(pool.freeSlots, equals(10));
      }
    });

    test('partial free leaves correct slot counts', () {
      final ptrs = List.generate(10, (_) => pool.alloc());
      // Free every other slot
      for (int i = 0; i < 10; i += 2) pool.free(ptrs[i]);
      expect(pool.usedSlots, equals(5));
      expect(pool.freeSlots, equals(5));
    });
  });

  group('ZeroGcPool — reset()', () {
    late ZeroGcPool pool;
    setUp(() => pool = ZeroGcPool(blockSize: 64, capacity: 20));
    tearDown(() => pool.dispose());

    test('reset() makes all slots free', () {
      for (int i = 0; i < 20; i++) pool.alloc();
      expect(pool.isFull, isTrue);
      pool.reset();
      expect(pool.usedSlots, equals(0));
      expect(pool.freeSlots, equals(20));
    });

    test('after reset(), full capacity is re-allocatable', () {
      for (int i = 0; i < 20; i++) pool.alloc();
      pool.reset();
      // Should be able to alloc all 20 again
      expect(() {
        for (int i = 0; i < 20; i++) pool.alloc();
      }, returnsNormally);
    });
  });

  group('ZeroGcPool — dispose()', () {
    test('dispose marks pool as disposed', () {
      final pool = ZeroGcPool(blockSize: 32, capacity: 5);
      pool.dispose();
      expect(pool.isDisposed, isTrue);
    });

    test('alloc after dispose throws ArenaDisposedException', () {
      final pool = ZeroGcPool(blockSize: 32, capacity: 5);
      pool.dispose();
      expect(() => pool.alloc(), throwsA(isA<ArenaDisposedException>()));
    });
  });

  // ── ZeroGcSlab tests ────────────────────────────────────────────────────

  group('ZeroGcSlab — Construction', () {
    test('creates Float slab with stride=3 (Vec3)', () {
      final slab = ZeroGcSlab<Float>(
          elementCount: 100, stride: 3, elemSize: sizeOf<Float>());
      expect(slab.elementCount, equals(100));
      expect(slab.stride, equals(3));
      expect(slab.slotBytes, greaterThanOrEqualTo(12)); // 3 × 4 bytes
      slab.dispose();
    });

    test('throws for stride resulting in slot < 8 bytes', () {
      // Int8 × 1 = 1 byte < 8 → should throw
      expect(
        () => ZeroGcSlab<Int8>(
            elementCount: 100, stride: 1, elemSize: sizeOf<Int8>()),
        throwsArgumentError,
      );
    });

    test('accepts minimum viable slot size (8 bytes)', () {
      // Int64 × 1 = 8 bytes ✓
      final slab = ZeroGcSlab<Int64>(
          elementCount: 50, stride: 1, elemSize: sizeOf<Int64>());
      expect(slab.slotBytes, greaterThanOrEqualTo(8));
      slab.dispose();
    });
  });

  group('ZeroGcSlab — alloc() / free()', () {
    late ZeroGcSlab<Double> colorSlab; // RGBA = 4 doubles = 32 bytes
    setUp(() => colorSlab = ZeroGcSlab<Double>(
        elementCount: 100, stride: 4, elemSize: sizeOf<Double>()));
    tearDown(() => colorSlab.dispose());

    test('alloc returns Pointer<Double>', () {
      final ptr = colorSlab.alloc();
      expect(ptr.address, isNonZero);
    });

    test('can write all stride elements', () {
      final rgba = colorSlab.alloc();
      (rgba + 0).value = 1.0; // R
      (rgba + 1).value = 0.5; // G
      (rgba + 2).value = 0.0; // B
      (rgba + 3).value = 1.0; // A
      expect((rgba + 0).value, closeTo(1.0, 1e-9));
      expect((rgba + 1).value, closeTo(0.5, 1e-9));
      expect((rgba + 3).value, closeTo(1.0, 1e-9));
    });

    test('freed slot can be reallocated', () {
      final p1 = colorSlab.alloc();
      final addr = p1.address;
      colorSlab.free(p1);
      final p2 = colorSlab.alloc();
      expect(p2.address, equals(addr));
    });

    test('alloc/free cycle 500 times', () {
      for (int i = 0; i < 500; i++) {
        final p = colorSlab.alloc();
        colorSlab.free(p);
      }
      expect(colorSlab.usedSlots, equals(0));
    });

    test('exhaustion throws ArenaOutOfMemoryException', () {
      for (int i = 0; i < 100; i++) colorSlab.alloc();
      expect(() => colorSlab.alloc(), throwsA(isA<ArenaOutOfMemoryException>()));
    });
  });

  // ── BumpAllocator tests ─────────────────────────────────────────────────

  group('BumpAllocator', () {
    late BumpAllocator ba;
    setUp(() => ba = BumpAllocator(capacity: 1.mb));
    tearDown(() { if (!ba.isDisposed) ba.dispose(); });

    test('allocate returns valid pointer', () {
      final ptr = ba.allocate(128);
      expect(ptr.address, isNonZero);
    });

    test('allocateTyped returns typed pointer', () {
      final ptr = ba.allocateTyped<Float>(64, elemSize: sizeOf<Float>());
      (ptr + 0).value = 2.71828;
      expect((ptr + 0).value, closeTo(2.71828, 0.0001));
    });

    test('usedBytes increases after allocation', () {
      expect(ba.usedBytes, equals(0));
      ba.allocate(1024);
      expect(ba.usedBytes, greaterThanOrEqualTo(1024));
    });

    test('reset() rewinds cursor', () {
      ba.allocate(64.kb);
      ba.reset();
      expect(ba.usedBytes, equals(0));
      expect(ba.isEmpty, isTrue);
    });

    test('throws ArenaOutOfMemoryException on overflow', () {
      expect(() => ba.allocate(2.mb), throwsA(isA<ArenaOutOfMemoryException>()));
    });
  });
}
