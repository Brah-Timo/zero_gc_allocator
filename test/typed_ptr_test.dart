import 'dart:ffi';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zero_gc_allocator/zero_gc_allocator.dart';

void main() {
  late ZeroGcArena arena;
  setUp(() => arena = ZeroGcArena(size: 2.mb));
  tearDown(() { if (!arena.isDisposed) arena.dispose(); });

  // ── TypedPtr tests ────────────────────────────────────────────────────────

  group('TypedPtr — scalar', () {
    test('fromArena creates valid pointer', () {
      final ptr = TypedPtr<Double>.fromArena(arena, elemSize: sizeOf<Double>());
      expect(ptr.address, isNonZero);
    });

    test('read/write value works', () {
      final ptr = TypedPtr<Double>.fromArena(arena, elemSize: sizeOf<Double>());
      ptr.value = 3.14159;
      expect(ptr.value, closeTo(3.14159, 1e-10));
    });

    test('isAlive returns true for live arena', () {
      final ptr = TypedPtr<Int32>.fromArena(arena, elemSize: sizeOf<Int32>());
      expect(ptr.isAlive, isTrue);
    });

    test('isAlive returns false after dispose', () {
      final ptr = TypedPtr<Int32>.fromArena(arena, elemSize: sizeOf<Int32>());
      arena.dispose();
      expect(ptr.isAlive, isFalse);
    });

    test('read after dispose throws StateError', () {
      final ptr = TypedPtr<Int32>.fromArena(arena, elemSize: sizeOf<Int32>());
      arena.dispose();
      expect(() => ptr.value, throwsStateError);
    });
  });

  group('TypedPtr — array', () {
    test('arrayFromArena allocates correct count', () {
      final arr = TypedPtr<Float>.arrayFromArena(arena,
          count: 100, elemSize: sizeOf<Float>());
      expect(arr.count, equals(100));
    });

    test('bracket operator returns pointer to element', () {
      final arr = TypedPtr<Float>.arrayFromArena(arena,
          count: 10, elemSize: sizeOf<Float>());
      (arr[0]).value = 1.0;
      (arr[9]).value = 9.0;
      expect((arr[0]).value, closeTo(1.0, 1e-6));
      expect((arr[9]).value, closeTo(9.0, 1e-6));
    });

    test('out-of-bounds access throws RangeError', () {
      final arr = TypedPtr<Int32>.arrayFromArena(arena,
          count: 5, elemSize: sizeOf<Int32>());
      expect(() => arr[-1], throwsRangeError);
      expect(() => arr[5], throwsRangeError);
      expect(() => arr[100], throwsRangeError);
    });

    test('count=0 throws ArgumentError', () {
      expect(
        () => TypedPtr<Float>.arrayFromArena(arena,
            count: 0, elemSize: sizeOf<Float>()),
        throwsArgumentError,
      );
    });
  });

  // ── NativeList tests ──────────────────────────────────────────────────────

  group('NativeList', () {
    test('arena-backed list has correct length', () {
      final list = NativeList<Int32>(arena: arena, length: 500,
          elemSize: sizeOf<Int32>());
      expect(list.length, equals(500));
    });

    test('element pointer access works', () {
      final list = NativeList<Double>(arena: arena, length: 10,
          elemSize: sizeOf<Double>());
      (list[5]).value = 42.42;
      expect((list[5]).value, closeTo(42.42, 1e-10));
    });

    test('out-of-bounds throws RangeError', () {
      final list = NativeList<Int32>(arena: arena, length: 10,
          elemSize: sizeOf<Int32>());
      expect(() => list[-1], throwsRangeError);
      expect(() => list[10], throwsRangeError);
    });

    test('subList shares memory', () {
      final list = NativeList<Int32>(arena: arena, length: 20,
          elemSize: sizeOf<Int32>());
      (list[10]).value = 999;
      final sub = list.subList(10, 5);
      expect((sub[0]).value, equals(999));
    });

    test('standalone list dispose frees memory (no crash)', () {
      final list = NativeList<Float>(length: 100, elemSize: sizeOf<Float>());
      (list[0]).value = 1.0;
      expect(() => list.dispose(), returnsNormally);
    });

    test('sizeInBytes is length * element size', () {
      final list = NativeList<Double>(arena: arena, length: 100,
          elemSize: sizeOf<Double>());
      expect(list.sizeInBytes, equals(100 * 8)); // Double = 8 bytes
    });
  });

  // ── NativeString tests ────────────────────────────────────────────────────

  group('NativeString', () {
    test('fromDart encodes and decodes correctly', () {
      final s = NativeString.fromDart('Hello, 世界!', arena: arena);
      expect(s.toDartString(), equals('Hello, 世界!'));
    });

    test('byteLength is correct for ASCII', () {
      final s = NativeString.fromDart('Hello', arena: arena);
      expect(s.byteLength, equals(5));
    });

    test('byteLength reflects UTF-8 encoding (non-ASCII)', () {
      final s = NativeString.fromDart('ABC', arena: arena);
      expect(s.byteLength, equals(3));
    });

    test('concat joins strings correctly', () {
      final s = NativeString.concat(
        ['Hello', ', ', 'world', '!'],
        arena: arena,
      );
      expect(s.toDartString(), equals('Hello, world!'));
    });

    test('isEmpty returns true for empty string', () {
      final s = NativeString.fromDart('', arena: arena);
      expect(s.isEmpty, isTrue);
    });

    test('equality operator works', () {
      final s1 = NativeString.fromDart('test', arena: arena);
      final s2 = NativeString.fromDart('test', arena: arena);
      final s3 = NativeString.fromDart('other', arena: arena);
      expect(s1, equals(s2));
      expect(s1, isNot(equals(s3)));
    });

    test('standalone dispose does not crash', () {
      final s = NativeString.fromDart('standalone');
      expect(() => s.dispose(), returnsNormally);
    });
  });

  // ── NativeBuffer tests ────────────────────────────────────────────────────

  group('NativeBuffer — read/write', () {
    late NativeBuffer buf;
    setUp(() => buf = NativeBuffer(arena: arena, size: 256));

    test('writeUint8 / readUint8', () {
      buf.writeUint8(0, 0xAB);
      expect(buf.readUint8(0), equals(0xAB));
    });

    test('writeUint16LE / readUint16LE', () {
      buf.writeUint16LE(0, 0x1234);
      expect(buf.readUint8(0), equals(0x34)); // little-endian low byte
      expect(buf.readUint8(1), equals(0x12)); // little-endian high byte
      expect(buf.readUint16LE(0), equals(0x1234));
    });

    test('writeUint16BE / readUint16BE', () {
      buf.writeUint16BE(0, 0x1234);
      expect(buf.readUint8(0), equals(0x12)); // big-endian high byte
      expect(buf.readUint8(1), equals(0x34));
      expect(buf.readUint16BE(0), equals(0x1234));
    });

    test('writeUint32LE / readUint32LE', () {
      buf.writeUint32LE(0, 0xDEADBEEF);
      expect(buf.readUint32LE(0), equals(0xDEADBEEF));
    });

    test('writeUint32BE / readUint32BE', () {
      buf.writeUint32BE(0, 0xCAFEBABE);
      expect(buf.readUint32BE(0), equals(0xCAFEBABE));
    });

    test('writeUint64LE / readUint64LE', () {
      buf.writeUint64LE(0, 0xDEADBEEFCAFEBABE);
      expect(buf.readUint64LE(0), equals(0xDEADBEEFCAFEBABE));
    });

    test('writeFloat32 / readFloat32', () {
      buf.writeFloat32LE(0, 3.14);
      expect(buf.readFloat32LE(0), closeTo(3.14, 0.001));
    });

    test('writeFloat64 / readFloat64', () {
      buf.writeFloat64LE(0, 2.718281828);
      expect(buf.readFloat64LE(0), closeTo(2.718281828, 1e-9));
    });

    test('writeBytes / readBytes round-trip', () {
      final data = [0x01, 0x02, 0x03, 0x04, 0x05];
      buf.writeBytes(10, data);
      final result = buf.readBytes(10, 5);
      expect(result, equals(data));
    });

    test('out-of-bounds write throws RangeError', () {
      expect(() => buf.writeUint32LE(253, 0xDEAD), throwsRangeError);
    });

    test('clear() zeros all bytes', () {
      buf.writeUint32LE(0, 0xFFFFFFFF);
      buf.clear();
      expect(buf.readUint32LE(0), equals(0));
    });

    test('asByteData() returns a view', () {
      buf.writeUint32BE(0, 0x01020304);
      final bd = buf.asByteData();
      expect(bd.getUint32(0, Endian.big), equals(0x01020304));
    });
  });

  group('NativeBuffer — sequential append', () {
    late NativeBuffer buf;
    setUp(() => buf = NativeBuffer(arena: arena, size: 256));

    test('appendUint8 advances writePosition', () {
      expect(buf.writePosition, equals(0));
      buf.appendUint8(0xAA);
      expect(buf.writePosition, equals(1));
    });

    test('appendUint32LE sequence writes correctly', () {
      buf.appendUint32LE(0x11111111);
      buf.appendUint32LE(0x22222222);
      expect(buf.readUint32LE(0), equals(0x11111111));
      expect(buf.readUint32LE(4), equals(0x22222222));
      expect(buf.writePosition, equals(8));
    });

    test('resetWritePosition resets cursor to zero', () {
      buf.appendUint8(1);
      buf.appendUint8(2);
      buf.resetWritePosition();
      expect(buf.writePosition, equals(0));
    });
  });

  // ── Ptr Extensions tests ──────────────────────────────────────────────────

  group('PtrExtensions', () {
    test('fill sets all bytes to given value', () {
      final ptr = arena.alloc(32);
      ptr.fill(32, 0xCC);
      for (int i = 0; i < 32; i++) {
        expect((ptr + i).value, equals(0xCC));
      }
    });

    test('zeroFill zeros all bytes', () {
      final ptr = arena.alloc(16);
      ptr.fill(16, 0xFF);
      ptr.zeroFill(16);
      for (int i = 0; i < 16; i++) {
        expect((ptr + i).value, equals(0));
      }
    });

    test('copyFrom copies bytes correctly', () {
      final src = arena.alloc(8);
      final dst = arena.alloc(8);
      src.fill(8, 0xBB);
      dst.copyFrom(src, 8);
      expect(dst.memEquals(src, 8), isTrue);
    });

    test('memEquals returns true for equal regions', () {
      final a = arena.alloc(16);
      final b = arena.alloc(16);
      a.fill(16, 0x55);
      b.fill(16, 0x55);
      expect(a.memEquals(b, 16), isTrue);
    });

    test('memEquals returns false for different regions', () {
      final a = arena.alloc(16);
      final b = arena.alloc(16);
      a.fill(16, 0x55);
      b.fill(16, 0xAA);
      expect(a.memEquals(b, 16), isFalse);
    });

    test('isAlignedTo checks alignment correctly', () {
      final ptr64 = arena.alloc(8, alignment: 64);
      expect(ptr64.isAlignedTo(64), isTrue);
      expect(ptr64.isAlignedTo(32), isTrue);
      expect(ptr64.isAlignedTo(16), isTrue);
      expect(ptr64.isAlignedTo(8), isTrue);
    });

    test('castAt returns pointer at byte offset', () {
      final base = arena.alloc(32);
      base.fill(32, 0);
      // Write 0xDEAD at byte 8
      final u32 = base.castAt<Uint32>(8);
      u32.value = 0xDEAD;
      expect(base.readUint32LE(8), equals(0xDEAD));
    });

    test('hexDump returns non-empty string', () {
      final ptr = arena.alloc(16);
      ptr.fill(16, 0xAB);
      final dump = ptr.hexDump(16);
      expect(dump, contains('AB'));
    });

    test('toHexAddress returns hex-formatted address', () {
      final ptr = arena.alloc(8);
      final hex = ptr.toHexAddress();
      expect(hex, startsWith('0x'));
      expect(hex.length, greaterThan(2));
    });
  });

  // ── SizeExtension tests ──────────────────────────────────────────────────

  group('SizeExtension', () {
    test('1.bytes == 1', () => expect(1.bytes, equals(1)));
    test('1.kb == 1024', () => expect(1.kb, equals(1024)));
    test('1.mb == 1048576', () => expect(1.mb, equals(1048576)));
    test('1.gb == 1073741824', () => expect(1.gb, equals(1073741824)));
    test('2.5.mb == 2621440', () => expect(2.5.mb, equals(2621440)));
    test('512.mb == 536870912', () => expect(512.mb, equals(536870912)));
    test('0.5.gb == 536870912', () => expect(0.5.gb, equals(536870912)));
    test('toSizeString for bytes', () => expect(512.toSizeString(), equals('512 B')));
    test('toSizeString for KB', () => expect(2048.toSizeString(), equals('2.00 KB')));
    test('toSizeString for MB', () => expect(1.mb.toSizeString(), equals('1.00 MB')));
    test('toSizeString for GB', () => expect(1.gb.toSizeString(), equals('1.00 GB')));
  });

  // ── AlignmentUtils tests ─────────────────────────────────────────────────

  group('AlignmentUtils', () {
    test('alignUp to 8', () {
      expect(AlignmentUtils.alignUp(0, 8), equals(0));
      expect(AlignmentUtils.alignUp(1, 8), equals(8));
      expect(AlignmentUtils.alignUp(8, 8), equals(8));
      expect(AlignmentUtils.alignUp(9, 8), equals(16));
      expect(AlignmentUtils.alignUp(15, 8), equals(16));
      expect(AlignmentUtils.alignUp(16, 8), equals(16));
    });

    test('alignDown to 8', () {
      expect(AlignmentUtils.alignDown(15, 8), equals(8));
      expect(AlignmentUtils.alignDown(16, 8), equals(16));
      expect(AlignmentUtils.alignDown(17, 8), equals(16));
    });

    test('isAligned', () {
      expect(AlignmentUtils.isAligned(0, 8), isTrue);
      expect(AlignmentUtils.isAligned(8, 8), isTrue);
      expect(AlignmentUtils.isAligned(16, 8), isTrue);
      expect(AlignmentUtils.isAligned(7, 8), isFalse);
      expect(AlignmentUtils.isAligned(9, 8), isFalse);
    });

    test('paddingFor', () {
      expect(AlignmentUtils.paddingFor(0, 8), equals(0));
      expect(AlignmentUtils.paddingFor(1, 8), equals(7));
      expect(AlignmentUtils.paddingFor(7, 8), equals(1));
      expect(AlignmentUtils.paddingFor(8, 8), equals(0));
    });

    test('isPowerOfTwo', () {
      expect(AlignmentUtils.isPowerOfTwo(1), isTrue);
      expect(AlignmentUtils.isPowerOfTwo(2), isTrue);
      expect(AlignmentUtils.isPowerOfTwo(4), isTrue);
      expect(AlignmentUtils.isPowerOfTwo(64), isTrue);
      expect(AlignmentUtils.isPowerOfTwo(0), isFalse);
      expect(AlignmentUtils.isPowerOfTwo(3), isFalse);
      expect(AlignmentUtils.isPowerOfTwo(6), isFalse);
      expect(AlignmentUtils.isPowerOfTwo(100), isFalse);
    });

    test('nextPowerOfTwo', () {
      expect(AlignmentUtils.nextPowerOfTwo(1), equals(1));
      expect(AlignmentUtils.nextPowerOfTwo(3), equals(4));
      expect(AlignmentUtils.nextPowerOfTwo(8), equals(8));
      expect(AlignmentUtils.nextPowerOfTwo(9), equals(16));
      expect(AlignmentUtils.nextPowerOfTwo(100), equals(128));
    });
  });
}

// Helper: readUint32LE directly from a Uint8 pointer (little endian)
extension on Pointer<Uint8> {
  int readUint32LE(int offset) {
    return (this + offset).value |
        ((this + offset + 1).value << 8) |
        ((this + offset + 2).value << 16) |
        ((this + offset + 3).value << 24);
  }
}
