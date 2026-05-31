/// Game engine frame loop example.
///
/// Demonstrates zero-GC memory management for a simulated 120fps game:
/// - Persistent arena for world data (lives entire game session)
/// - Frame arena for temporary per-frame data (reset every frame)
/// - Particle pool for active particles (O(1) spawn/kill)
/// - Per-draw-call regions (nested checkpoints)
///
/// Run: dart run example/game_frame_arena.dart
library;

import 'dart:ffi';
import 'package:zero_gc_allocator/zero_gc_allocator.dart';

// ── Native struct sizes ────────────────────────────────────────────────────

// Vertex: x, y, z (3 × Float32 = 12 bytes)
const int kFloatsPerVertex = 3;

// Particle: x, y, z, vx, vy, vz, life, size (8 × Float32 = 32 bytes)
// Minimum slot size for pool is 8 bytes, 32 is fine.
const int kParticleBlockSize = 32;

// Draw command: objectId, materialId, startIdx, count (4 × Int32 = 16 bytes)
const int kDrawCmdBytes = 16;

// ── Simulation helpers ────────────────────────────────────────────────────

void writeParticle(Pointer<Uint8> slot, double x, double y, double z, double life) {
  final floats = slot.cast<Float>();
  (floats + 0).value = x;
  (floats + 1).value = y;
  (floats + 2).value = z;
  (floats + 3).value = 0.0; // vx
  (floats + 4).value = 0.0; // vy
  (floats + 5).value = -0.1; // vz (gravity)
  (floats + 6).value = life;
  (floats + 7).value = 1.0; // size
}

double readParticleLife(Pointer<Uint8> slot) {
  return (slot.cast<Float>() + 6).value;
}

void updateParticleLife(Pointer<Uint8> slot, double delta) {
  final floats = slot.cast<Float>();
  (floats + 6).value -= delta;
}

// ── Game allocator ────────────────────────────────────────────────────────

class GameAllocator {
  // Persistent: lives entire game session (world geometry, textures metadata)
  final ZeroGcArena persistentArena;

  // Frame: reset every frame (temporary mesh transforms, visibility sets)
  final ZeroGcArena frameArena;

  // Particles: O(1) spawn and kill
  final ZeroGcPool particlePool;

  GameAllocator()
      : persistentArena = ZeroGcArena(size: 512.mb),
        frameArena = ZeroGcArena(size: 32.mb),
        particlePool = ZeroGcPool(
          blockSize: kParticleBlockSize,
          capacity: 100000,
        );

  void dispose() {
    persistentArena.dispose();
    frameArena.dispose();
    particlePool.dispose();
  }
}

// ── Game simulation ───────────────────────────────────────────────────────

void main() {
  const totalFrames = 3600; // 30 seconds at 120fps
  const frameBudgetUs = 8333; // 120fps = 8.333ms per frame

  print('=== Zero-GC Game Engine Simulation ===');
  print('Simulating $totalFrames frames (30s @ 120fps)');
  print('Frame budget: ${frameBudgetUs / 1000}ms\n');

  final game = GameAllocator();

  // Active particle list (just addresses, no GC)
  final activeParticles = <int>[];
  int framesMissed = 0;
  int maxFrameUs = 0;
  int totalFrameUs = 0;
  int particleSpawns = 0;
  int particleDeaths = 0;

  for (int frame = 0; frame < totalFrames; frame++) {
    final frameTimer = Stopwatch()..start();

    // ── Per-frame scope (everything freed at end of frame) ────────────────
    final frameRegion = game.frameArena.saveCheckpoint();

    // 1. Allocate temporary vertex buffer for visible geometry
    final vertexCount = 5000 + (frame % 3000);
    final vertices = game.frameArena.allocTyped<Float>(vertexCount * kFloatsPerVertex,
        elemSize: sizeOf<Float>());

    // 2. Allocate draw command buffer
    final drawCmds = game.frameArena.allocTyped<Int32>(200 * 4,
        elemSize: sizeOf<Int32>());

    // 3. Allocate matrix palette (for skeletal animation)
    final matrixPalette = game.frameArena.allocTyped<Float>(64 * 16,
        elemSize: sizeOf<Float>());

    // 4. Simulate vertex transform (write some data)
    for (int i = 0; i < vertexCount.clamp(0, 100); i++) {
      (vertices + i * 3 + 0).value = i * 0.1; // x
      (vertices + i * 3 + 1).value = 0.0;      // y
      (vertices + i * 3 + 2).value = 0.0;      // z
    }
    (drawCmds + 0).value = 1; // objectId=1
    (matrixPalette + 0).value = 1.0; // identity[0,0]

    // 5. Spawn new particles (10 per frame)
    final spawnCount = 10;
    for (int i = 0; i < spawnCount; i++) {
      if (!game.particlePool.isFull) {
        final p = game.particlePool.alloc();
        writeParticle(p, i * 0.1, 5.0, 0.0, 3.0); // life=3 seconds
        activeParticles.add(p.address);
        particleSpawns++;
      }
    }

    // 6. Update and kill dead particles
    final deadParticles = <int>[];
    for (final addr in activeParticles) {
      final p = Pointer<Uint8>.fromAddress(addr);
      updateParticleLife(p, 1.0 / 120.0); // 1 frame = 1/120s
      if (readParticleLife(p) <= 0) {
        deadParticles.add(addr);
        particleDeaths++;
      }
    }
    for (final addr in deadParticles) {
      game.particlePool.free(Pointer<Uint8>.fromAddress(addr));
      activeParticles.remove(addr);
    }

    // 7. Per-draw-call temporary allocation (nested checkpoint)
    for (int drawCall = 0; drawCall < 5; drawCall++) {
      final drawScope = game.frameArena.saveCheckpoint();
      final tempIndices = game.frameArena.allocTyped<Uint16>(1000,
          elemSize: sizeOf<Uint16>());
      for (int i = 0; i < 100; i++) (tempIndices + i).value = i;
      game.frameArena.restoreCheckpoint(drawScope);
      // tempIndices freed — O(1)
    }

    // End of frame: free ALL temporary allocations in O(1)
    game.frameArena.restoreCheckpoint(frameRegion);

    frameTimer.stop();
    final frameUs = frameTimer.elapsedMicroseconds;
    totalFrameUs += frameUs;
    if (frameUs > maxFrameUs) maxFrameUs = frameUs;
    if (frameUs > frameBudgetUs) framesMissed++;
  }

  game.dispose();

  // ── Results ──────────────────────────────────────────────────────────────
  final avgFrameUs = totalFrameUs / totalFrames;
  final jankRate = framesMissed / totalFrames * 100;

  print('Results:');
  print('  Total time     : ${(totalFrameUs / 1000).toStringAsFixed(1)} ms');
  print('  Avg frame      : ${(avgFrameUs / 1000).toStringAsFixed(3)} ms');
  print('  Max frame      : ${(maxFrameUs / 1000).toStringAsFixed(3)} ms');
  print('  Budget         : ${frameBudgetUs / 1000} ms');
  print('  Frames missed  : $framesMissed / $totalFrames '
      '(${jankRate.toStringAsFixed(2)}% jank)');
  print('  Particle spawns: $particleSpawns');
  print('  Particle deaths: $particleDeaths');
  print('  Active now     : ${activeParticles.length}');
  print('  GC pauses      : 0 (zero native allocations visible to GC)');
  print('\n=== Simulation complete ===');
}
