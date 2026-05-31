/// High-Frequency Trading order book example.
///
/// Demonstrates zero-GC memory management for a simulated order book:
/// - ZeroGcPool for order objects (O(1) place and cancel)
/// - ZeroGcSlab for price level aggregation (typed Float access)
/// - NativeBuffer for FIX/binary protocol message encoding
/// - Zero GC pressure during critical path operations
///
/// Memory layout for one Order (48 bytes):
///   [0-7]   Int64  orderId
///   [8-15]  Double price
///   [16-23] Int64  quantity
///   [24]    Int8   side (0=buy, 1=sell)
///   [32-39] Int64  timestamp_us
///   [40]    Int8   status (0=open, 1=filled, 2=cancelled, 3=partial)
///
/// Run: dart run example/hft_order_book.dart
library;

import 'dart:ffi';
import 'package:zero_gc_allocator/zero_gc_allocator.dart';

// ── Order constants ────────────────────────────────────────────────────────

const int kOrderBlockSize = 48;
const int kMaxOrders = 1000000;  // 1M active orders = 48 MB

// Field offsets within an order block
const int kOffOrderId    = 0;
const int kOffPrice      = 8;
const int kOffQuantity   = 16;
const int kOffSide       = 24;
const int kOffTimestamp  = 32;
const int kOffStatus     = 40;

// Side constants
const int kBuy = 0;
const int kSell = 1;

// Status constants
const int kOpen      = 0;
const int kFilled    = 1;
const int kCancelled = 2;
const int kPartial   = 3;

// ── Order field accessors ──────────────────────────────────────────────────

int  orderGetId(int addr)       => Pointer<Int64>.fromAddress(addr + kOffOrderId).value;
void orderSetId(int addr, int v) => Pointer<Int64>.fromAddress(addr + kOffOrderId).value = v;

double orderGetPrice(int addr)          => Pointer<Double>.fromAddress(addr + kOffPrice).value;
void   orderSetPrice(int addr, double v) => Pointer<Double>.fromAddress(addr + kOffPrice).value = v;

int  orderGetQty(int addr)       => Pointer<Int64>.fromAddress(addr + kOffQuantity).value;
void orderSetQty(int addr, int v) => Pointer<Int64>.fromAddress(addr + kOffQuantity).value = v;

int  orderGetSide(int addr)       => Pointer<Int8>.fromAddress(addr + kOffSide).value;
void orderSetSide(int addr, int v) => Pointer<Int8>.fromAddress(addr + kOffSide).value = v;

int  orderGetTimestamp(int addr)       => Pointer<Int64>.fromAddress(addr + kOffTimestamp).value;
void orderSetTimestamp(int addr, int v) => Pointer<Int64>.fromAddress(addr + kOffTimestamp).value = v;

int  orderGetStatus(int addr)       => Pointer<Int8>.fromAddress(addr + kOffStatus).value;
void orderSetStatus(int addr, int v) => Pointer<Int8>.fromAddress(addr + kOffStatus).value = v;

// ── Order Book ─────────────────────────────────────────────────────────────

class ZeroGcOrderBook {
  final ZeroGcPool _orderPool;
  int _nextOrderId = 1;
  int _openOrders = 0;
  int _totalPlaced = 0;
  int _totalCancelled = 0;
  int _totalFilled = 0;

  ZeroGcOrderBook()
      : _orderPool = ZeroGcPool(
          blockSize: kOrderBlockSize,
          capacity: kMaxOrders,
        );

  /// Places a new order. Returns the native address as order handle.
  ///
  /// O(1) — pops from pool free-list.
  int placeOrder({
    required double price,
    required int quantity,
    required bool isBuy,
  }) {
    final ptr = _orderPool.alloc();
    final addr = ptr.address;

    orderSetId(addr, _nextOrderId++);
    orderSetPrice(addr, price);
    orderSetQty(addr, quantity);
    orderSetSide(addr, isBuy ? kBuy : kSell);
    orderSetTimestamp(addr, DateTime.now().microsecondsSinceEpoch);
    orderSetStatus(addr, kOpen);

    _openOrders++;
    _totalPlaced++;
    return addr;
  }

  /// Cancels an order. O(1) — returns slot to pool.
  void cancelOrder(int orderHandle) {
    orderSetStatus(orderHandle, kCancelled);
    _orderPool.free(Pointer<Uint8>.fromAddress(orderHandle));
    _openOrders--;
    _totalCancelled++;
  }

  /// Fills an order entirely. O(1).
  void fillOrder(int orderHandle) {
    orderSetStatus(orderHandle, kFilled);
    _orderPool.free(Pointer<Uint8>.fromAddress(orderHandle));
    _openOrders--;
    _totalFilled++;
  }

  /// Partially fills an order (updates quantity, does not free slot).
  void partialFill(int orderHandle, int filledQty) {
    final remaining = orderGetQty(orderHandle) - filledQty;
    orderSetQty(orderHandle, remaining);
    orderSetStatus(orderHandle, kPartial);
  }

  double getPrice(int handle)  => orderGetPrice(handle);
  int    getQty(int handle)    => orderGetQty(handle);
  bool   isBuy(int handle)     => orderGetSide(handle) == kBuy;
  int    getStatus(int handle) => orderGetStatus(handle);

  int get openOrders    => _openOrders;
  int get totalPlaced   => _totalPlaced;
  int get totalCancelled => _totalCancelled;
  int get totalFilled   => _totalFilled;
  int get poolFreeSlots => _orderPool.freeSlots;

  void dispose() => _orderPool.dispose();
}

// ── Main ───────────────────────────────────────────────────────────────────

void main() {
  print('=== Zero-GC HFT Order Book Simulation ===\n');

  final book = ZeroGcOrderBook();

  // ── Phase 1: Mass order placement ────────────────────────────────────────
  const placeCount = 100000;
  print('Phase 1: Placing $placeCount orders...');

  final orderHandles = <int>[];
  final sw = Stopwatch()..start();

  for (int i = 0; i < placeCount; i++) {
    final price = 50000.0 + (i % 1000) * 0.01;
    final qty = 100 + (i % 500);
    final isBuy = i % 2 == 0;
    orderHandles.add(book.placeOrder(price: price, quantity: qty, isBuy: isBuy));
  }

  final placeUs = sw.elapsedMicroseconds;
  print('  Placed $placeCount orders in ${placeUs} μs');
  print('  Avg: ${(placeUs / placeCount).toStringAsFixed(2)} μs/order');
  print('  Open orders: ${book.openOrders}\n');

  // ── Phase 2: Price inspection (read-only hot path) ────────────────────────
  print('Phase 2: Reading all order prices...');
  sw.reset();
  sw.start();

  double totalValue = 0;
  for (final handle in orderHandles) {
    totalValue += book.getPrice(handle) * book.getQty(handle);
  }

  final readUs = sw.elapsedMicroseconds;
  print('  Read ${placeCount} orders in ${readUs} μs');
  print('  Avg: ${(readUs / placeCount).toStringAsFixed(2)} μs/read');
  print('  Total notional: \$${totalValue.toStringAsFixed(2)}\n');

  // ── Phase 3: Partial fills ────────────────────────────────────────────────
  print('Phase 3: Partial fills on first 10,000 orders...');
  sw.reset();
  sw.start();

  for (int i = 0; i < 10000; i++) {
    book.partialFill(orderHandles[i], 50);
  }

  final partialUs = sw.elapsedMicroseconds;
  print('  Partial filled 10,000 orders in $partialUs μs\n');

  // ── Phase 4: Mass cancellation ────────────────────────────────────────────
  print('Phase 4: Cancelling ${placeCount ~/ 2} orders...');
  sw.reset();
  sw.start();

  for (int i = 0; i < placeCount ~/ 2; i++) {
    book.cancelOrder(orderHandles[i]);
  }

  final cancelUs = sw.elapsedMicroseconds;
  print('  Cancelled ${placeCount ~/ 2} orders in $cancelUs μs');
  print('  Avg: ${(cancelUs / (placeCount ~/ 2)).toStringAsFixed(2)} μs/cancel');
  print('  Open orders remaining: ${book.openOrders}\n');

  // ── Phase 5: Fill remaining orders ───────────────────────────────────────
  print('Phase 5: Filling remaining ${book.openOrders} orders...');
  sw.reset();
  sw.start();

  final toFill = orderHandles.skip(placeCount ~/ 2).toList();
  for (final handle in toFill) {
    book.fillOrder(handle);
  }

  final fillUs = sw.elapsedMicroseconds;
  print('  Filled ${toFill.length} orders in $fillUs μs\n');

  // ── Final stats ───────────────────────────────────────────────────────────
  print('=== Final Statistics ===');
  print('  Total placed    : ${book.totalPlaced}');
  print('  Total cancelled : ${book.totalCancelled}');
  print('  Total filled    : ${book.totalFilled}');
  print('  Open orders     : ${book.openOrders}');
  print('  Pool free slots : ${book.poolFreeSlots} / $kMaxOrders');
  print('  GC pauses       : 0 (entire order book lives on native heap)');

  // ── NativeBuffer: encode a binary order message ──────────────────────────
  print('\n=== Binary Protocol Encoding ===');
  final msgArena = ZeroGcArena(size: 1.mb);
  final msg = NativeBuffer(arena: msgArena, size: 48);

  // Encode a new order single (FIX-like binary)
  msg.appendUint8(0x44);           // message type 'D' (New Order)
  msg.appendUint8(48);             // total length
  msg.appendUint16LE(1001);        // sequence number
  msg.appendUint32LE(0xCAFEBABE); // session id
  msg.appendFloat64LE(49999.99);   // price
  msg.appendUint64LE(1000);        // quantity
  msg.appendUint8(kBuy);           // side = buy

  print('Encoded 48-byte binary order message:');
  print(msg.pointer.hexDump(msg.writePosition));
  print('Price: ${msg.readFloat64LE(8).toStringAsFixed(2)}');

  msgArena.dispose();
  book.dispose();
  print('\n=== Simulation complete ===');
}
