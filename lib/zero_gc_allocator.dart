/// # zero_gc_allocator
///
/// Ultra-high-performance manual memory management for Dart/Flutter.
/// Bypasses the Garbage Collector entirely using FFI-backed native memory.
///
/// ## Architecture
///
/// All allocators share one fundamental principle: memory lives on the
/// **native heap** (via `dart:ffi`), completely invisible to Dart's GC.
/// This eliminates Stop-The-World pauses at the cost of manual lifetime
/// management — you decide when memory is freed.
///
/// ## Quick Start
///
/// ```dart
/// import 'package:zero_gc_allocator/zero_gc_allocator.dart';
///
/// void main() {
///   // One syscall allocates 1 GB on the native heap
///   final arena = ZeroGcArena(size: 1.gb);
///
///   // O(1) bump-pointer allocation — GC never involved
///   final floats = arena.allocTyped<Float>(256, elemSize: sizeOf<Float>());
///   (floats + 0).value = 3.14159;
///
///   // Scoped allocations with checkpoints
///   final region = arena.saveCheckpoint();
///   final temp = arena.alloc(4096);
///   arena.restoreCheckpoint(region); // temp freed in O(1)
///
///   // Reuse the entire arena (O(1) cursor rewind)
///   arena.reset();
///
///   // Release native block
///   arena.dispose();
/// }
/// ```
///
/// ## Allocator Types
///
/// | Type               | alloc | free | reset | Individual free |
/// |--------------------|-------|------|-------|-----------------|
/// | [ZeroGcArena]      | O(1)  | N/A  | O(1)  | ❌              |
/// | [ZeroGcPool]       | O(1)  | O(1) | O(n)  | ✅              |
/// | [ZeroGcSlab]       | O(1)  | O(1) | O(n)  | ✅ (typed)      |
/// | [BumpAllocator]    | O(1)  | N/A  | O(1)  | ❌ (standalone) |
///
/// ## Safety Rules
///
/// 1. Never use a native `Pointer` after [ZeroGcArena.dispose].
/// 2. Never use a native `Pointer` after [ZeroGcArena.reset].
/// 3. Never store data larger than `ZeroGcPool.blockSize` in a pool slot.
/// 4. Arenas are NOT thread-safe — one per `Isolate`.
/// 5. [NativeBuffer.asByteData] views are invalidated after reset/dispose.
library zero_gc_allocator;

// ── Core arena ──────────────────────────────────────────────────────────────
export 'src/arena/zero_gc_arena.dart';
export 'src/arena/arena_stats.dart';
export 'src/arena/arena_region.dart';

// ── Specialized allocators ───────────────────────────────────────────────────
export 'src/allocators/bump_allocator.dart';
export 'src/allocators/pool_allocator.dart';
export 'src/allocators/slab_allocator.dart';

// ── Typed high-level wrappers ────────────────────────────────────────────────
export 'src/typed/typed_ptr.dart';
export 'src/typed/native_list.dart';
export 'src/typed/native_string.dart';
export 'src/typed/native_buffer.dart';

// ── Developer-friendly extensions ───────────────────────────────────────────
export 'src/extensions/size_extensions.dart';
export 'src/extensions/ptr_extensions.dart';

// ── Exceptions ───────────────────────────────────────────────────────────────
export 'src/exceptions/arena_exception.dart';
export 'src/exceptions/alignment_exception.dart';

// ── Utilities (exposed for advanced users) ───────────────────────────────────
export 'src/utils/alignment.dart';
export 'src/utils/memory_guard.dart';
export 'src/utils/platform_utils.dart';
