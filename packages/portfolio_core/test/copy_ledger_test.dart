import 'dart:typed_data';

import 'package:portfolio_core/portfolio_core.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  late MemoryRecordFolder from;
  late MemoryRecordFolder to;
  final d = DateTime.utc(2026, 1, 1);

  setUp(() {
    from = MemoryRecordFolder()..descriptor = descriptorBytes();
    to = MemoryRecordFolder();
  });

  void put(LedgerRecord r) => from.records[r.fileName] = r.encode();

  test(
    'copies descriptor and records; second run is all alreadyPresent',
    () async {
      put(upsert(tx: buy(on: d)));
      put(
        upsert(
          tx: buy(on: d, price: '2'),
        ),
      );
      var rep = await copyLedger(from, to);
      expect([rep.copied, rep.alreadyPresent, rep.errors.length], [2, 0, 0]);
      expect(to.descriptor, from.descriptor);
      rep = await copyLedger(from, to);
      expect([rep.copied, rep.alreadyPresent, rep.errors.length], [0, 2, 0]);
    },
  );

  test('voided transaction stays voided after restore', () async {
    final a = upsert(tx: buy(on: d));
    final v = voidOf(a);
    put(a);
    put(v);
    await copyLedger(from, to);
    final s = await LedgerScanner(to, MemoryBlobStore()).scan(nowUtc: testNow);
    expect(s.ledger.transactions, isEmpty);
    expect(s.ledger.leaves.values.single.recordId, v.recordId);
  });

  test('other portfolio at destination: error, nothing written', () async {
    put(upsert(tx: buy(on: d)));
    to.descriptor = descriptorBytes('33333333-3333-4333-8333-333333333333');
    final rep = await copyLedger(from, to);
    expect(rep.errors, isNotEmpty);
    expect(rep.copied, 0);
    expect(to.records, isEmpty);
  });

  test('any undecodable source record: errors, nothing written', () async {
    put(upsert(tx: buy(on: d)));
    from.records['$testDeviceId.json'] = Uint8List.fromList([123]);
    final rep = await copyLedger(from, to);
    expect(rep.errors, hasLength(1));
    expect(rep.copied, 0);
    expect(to.records, isEmpty);
    expect(to.descriptor, isNull);
  });

  test('missing source descriptor is an error', () async {
    from.descriptor = null;
    expect((await copyLedger(from, to)).errors, isNotEmpty);
  });

  test('different content under same name is an error', () async {
    final r = upsert(tx: buy(on: d));
    put(r);
    to.descriptor = from.descriptor;
    to.records[r.fileName] = upsert(
      tx: buy(on: d, price: '5'),
    ).encode();
    final rep = await copyLedger(from, to);
    expect(rep.errors, hasLength(1));
    expect(rep.copied, 0);
  });
}
