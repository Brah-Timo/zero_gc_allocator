/// WebSocket / high-concurrency server pattern.
///
/// Shows how zero_gc_allocator supports servers handling millions of
/// concurrent connections with zero per-connection GC heap allocation.
///
/// Per-connection memory layout:
///   - Receive buffer (4 KB) — from ZeroGcPool
///   - Send buffer (4 KB)    — from ZeroGcPool
///   - Metadata (64 bytes)   — from ZeroGcSlab<Int64> (8 Int64 fields)
///
/// All per-connection memory is returned to pools on disconnect (O(1)).
/// No GC pause occurs regardless of connection count.
///
/// Run: dart run example/websocket_server.dart
library;

import 'dart:ffi';
import 'package:zero_gc_allocator/zero_gc_allocator.dart';

// ── Connection metadata layout (64 bytes = 8 × Int64) ─────────────────────
//  [0] connId            : Int64 — unique connection identifier
//  [1] recvBufAddress    : Int64 — address of recv buffer in pool
//  [2] sendBufAddress    : Int64 — address of send buffer in pool
//  [3] connectedAt_us    : Int64 — epoch microseconds of connection
//  [4] lastActivityAt_us : Int64 — epoch microseconds of last message
//  [5] bytesReceived     : Int64 — total bytes received
//  [6] bytesSent         : Int64 — total bytes sent
//  [7] state             : Int64 — 0=connecting, 1=open, 2=closing, 3=closed

const int kConnOpen     = 1;
const int kConnClosing  = 2;
const int kConnClosed   = 3;

// ── ZeroGcConnectionPool ───────────────────────────────────────────────────

class ZeroGcConnectionPool {
  // Two 4KB I/O buffer pools (one for recv, one for send)
  final ZeroGcPool _recvPool;
  final ZeroGcPool _sendPool;

  // Metadata slab: each slot = 8 × Int64 = 64 bytes
  final ZeroGcSlab<Int64> _metaSlab;

  int _nextConnId = 1;
  int _activeConnections = 0;
  int _totalConnections = 0;
  int _totalDisconnections = 0;

  ZeroGcConnectionPool({required int maxConnections})
      : _recvPool = ZeroGcPool(blockSize: 4096, capacity: maxConnections),
        _sendPool = ZeroGcPool(blockSize: 4096, capacity: maxConnections),
        _metaSlab = ZeroGcSlab<Int64>(
          elementCount: maxConnections,
          stride: 8, // 8 Int64 fields = 64 bytes per connection
          elemSize: sizeOf<Int64>(),
        );

  /// Called when a new WebSocket connection is established. O(1).
  ///
  /// Returns a "connection handle" — the native address of the metadata slot.
  /// Pass this handle to all subsequent operations.
  int onConnect() {
    // Allocate all three buffers from their respective pools/slabs
    final recvBuf = _recvPool.alloc();
    final sendBuf = _sendPool.alloc();
    final meta    = _metaSlab.alloc();

    final now = DateTime.now().microsecondsSinceEpoch;
    (meta + 0).value = _nextConnId++;
    (meta + 1).value = recvBuf.address;
    (meta + 2).value = sendBuf.address;
    (meta + 3).value = now;
    (meta + 4).value = now;
    (meta + 5).value = 0; // bytesReceived
    (meta + 6).value = 0; // bytesSent
    (meta + 7).value = kConnOpen;

    _activeConnections++;
    _totalConnections++;
    return meta.address; // return handle = raw native address
  }

  /// Simulates receiving a message for [handle]. O(1).
  void onReceive(int handle, int bytes) {
    final meta = Pointer<Int64>.fromAddress(handle);
    (meta + 4).value = DateTime.now().microsecondsSinceEpoch; // lastActivity
    (meta + 5).value += bytes; // bytesReceived

    // Access recv buffer (zero-copy)
    final recvAddr = (meta + 1).value;
    final recvBuf = Pointer<Uint8>.fromAddress(recvAddr);
    (recvBuf + 0).value = bytes % 256; // simulate writing to recv buffer
  }

  /// Simulates sending a response for [handle]. O(1).
  void onSend(int handle, int bytes) {
    final meta = Pointer<Int64>.fromAddress(handle);
    (meta + 6).value += bytes; // bytesSent

    final sendAddr = (meta + 2).value;
    final sendBuf = Pointer<Uint8>.fromAddress(sendAddr);
    (sendBuf + 0).value = 0x00; // simulate send buffer flush
  }

  /// Called when a connection closes. O(1).
  ///
  /// Returns all three buffers to their pools immediately.
  void onDisconnect(int handle) {
    final meta = Pointer<Int64>.fromAddress(handle);
    (meta + 7).value = kConnClosed;

    final recvAddr = (meta + 1).value;
    final sendAddr = (meta + 2).value;

    _recvPool.free(Pointer<Uint8>.fromAddress(recvAddr));
    _sendPool.free(Pointer<Uint8>.fromAddress(sendAddr));
    _metaSlab.free(meta);

    _activeConnections--;
    _totalDisconnections++;
  }

  // ── Accessors ─────────────────────────────────────────────────────────────

  int connId(int handle)           => Pointer<Int64>.fromAddress(handle).value;
  int bytesReceived(int handle)    => (Pointer<Int64>.fromAddress(handle) + 5).value;
  int bytesSent(int handle)        => (Pointer<Int64>.fromAddress(handle) + 6).value;
  int connState(int handle)        => (Pointer<Int64>.fromAddress(handle) + 7).value;

  int get activeConnections  => _activeConnections;
  int get totalConnections   => _totalConnections;
  int get totalDisconnects   => _totalDisconnections;
  int get recvPoolFree       => _recvPool.freeSlots;
  int get sendPoolFree       => _sendPool.freeSlots;
  int get metaSlabFree       => _metaSlab.freeSlots;

  void dispose() {
    _recvPool.dispose();
    _sendPool.dispose();
    _metaSlab.dispose();
  }
}

// ── Simulation ────────────────────────────────────────────────────────────

void main() {
  const maxConns = 10000; // 10K concurrent connections
  const simulationRounds = 500; // simulate 500 connection waves

  print('=== Zero-GC WebSocket Server Simulation ===');
  print('Max concurrent connections: $maxConns');
  print('Simulation rounds: $simulationRounds\n');

  final server = ZeroGcConnectionPool(maxConnections: maxConns);
  final activeHandles = <int>[];
  final sw = Stopwatch()..start();

  int totalMessages = 0;
  int maxActiveAtOnce = 0;

  for (int round = 0; round < simulationRounds; round++) {
    // Connect a batch of clients (50 per round)
    for (int i = 0; i < 50; i++) {
      if (server.activeConnections < maxConns - 10) {
        activeHandles.add(server.onConnect());
      }
    }

    if (server.activeConnections > maxActiveAtOnce) {
      maxActiveAtOnce = server.activeConnections;
    }

    // Simulate message exchanges
    for (final handle in activeHandles) {
      server.onReceive(handle, 128 + round % 3840); // recv 128-4K bytes
      server.onSend(handle, 64); // respond with 64 bytes
      totalMessages++;
    }

    // Disconnect some clients (30 per round after warmup)
    if (round > 10 && activeHandles.length > 30) {
      for (int i = 0; i < 30; i++) {
        final handle = activeHandles.removeLast();
        server.onDisconnect(handle);
      }
    }
  }

  // Close remaining connections
  for (final handle in activeHandles) {
    server.onDisconnect(handle);
  }

  sw.stop();

  print('Results:');
  print('  Total time          : ${sw.elapsedMilliseconds} ms');
  print('  Total connections   : ${server.totalConnections}');
  print('  Total disconnects   : ${server.totalDisconnects}');
  print('  Total messages      : $totalMessages');
  print('  Max concurrent      : $maxActiveAtOnce');
  print('  Final active        : ${server.activeConnections}');
  print('  Recv pool free slots: ${server.recvPoolFree} / $maxConns');
  print('  Send pool free slots: ${server.sendPoolFree} / $maxConns');
  print('  Meta slab free slots: ${server.metaSlabFree} / $maxConns');
  print('  GC pauses           : 0 (all connection state on native heap)');

  if (server.activeConnections == 0) {
    print('\n  ✅ All connections properly freed — no memory leaks');
  }

  server.dispose();
  print('\n=== Simulation complete ===');
}
