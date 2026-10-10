import 'dart:convert';
import 'dart:typed_data';

import 'package:portfolio_core/portfolio_core.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// Reads back different bytes than were written after the first read.
class _LyingFolder extends MemoryRecordFolder {
  _LyingFolder(this.lie);
  final Uint8List lie;
  int reads = 0;

  @override
  Future<Uint8List?> readRecordFile(String name) async =>
      reads++ == 0 ? null : lie;
}

LedgerRecord _rec([String price = '1']) => upsert(
  tx: buy(on: DateTime.utc(2026, 1, 1), price: price),
);

void main() {
  late MemoryRecordFolder folder;
  late MemoryBlobStore pending;
  late Publisher publisher;

  setUp(() {
    folder = MemoryRecordFolder();
    pending = MemoryBlobStore();
    publisher = Publisher(folder, pending);
  });

  test('publish writes the file and clears pending', () async {
    final r = _rec();
    await publisher.publish(r);
    expect(await folder.listRecordFiles(), [r.fileName]);
    expect(await folder.readRecordFile(r.fileName), r.encode());
    expect(await pending.keys(), isEmpty);
  });

  test('publishing the same record twice is a no-op', () async {
    final r = _rec();
    await publisher.publish(r);
    await publisher.publish(r);
    expect(await folder.listRecordFiles(), [r.fileName]);
    expect(await pending.keys(), isEmpty);
  });

  test('different content under the same name is a collision', () async {
    final r = _rec();
    folder.records[r.fileName] = _rec('2').encode();
    await expectLater(
      publisher.publish(r),
      throwsA(
        isA<PublishException>().having((e) => e.code, 'code', 'collision'),
      ),
    );
    expect(await pending.keys(), [r.recordId]);
    expect(folder.records[r.fileName], isNot(r.encode()));
  });

  for (final (label, bytes) in [
    (
      'another portfolio',
      LedgerRecord.newUpsert(
        portfolioId: '33333333-3333-4333-8333-333333333333',
        deviceId: testDeviceId,
        transaction: buy(on: DateTime.utc(2026, 1, 1)),
        now: testNow,
      ).encode(),
    ),
    (
      'schema_version 99',
      Uint8List.fromList(
        utf8.encode(
          utf8
              .decode(_rec().encode())
              .replaceFirst('"schema_version": 1', '"schema_version": 99'),
        ),
      ),
    ),
  ]) {
    test('complete file with $label is a collision, left untouched', () async {
      final r = _rec();
      folder.records[r.fileName] = bytes;
      await expectLater(
        publisher.publish(r),
        throwsA(
          isA<PublishException>().having((e) => e.code, 'code', 'collision'),
        ),
      );
      expect(folder.records[r.fileName], bytes);
      expect(await pending.keys(), [r.recordId]);
    });
  }

  test('a truncated file under that name is repaired', () async {
    final r = _rec();
    folder.records[r.fileName] = r.encode().sublist(0, 20);
    await publisher.publish(r);
    expect(folder.records[r.fileName], r.encode());
    expect(await pending.keys(), isEmpty);
  });

  test('read-back of other bytes is verify_failed and keeps pending', () async {
    final r = _rec();
    final f = _LyingFolder(_rec('2').encode());
    await expectLater(
      Publisher(f, pending).publish(r),
      throwsA(
        isA<PublishException>().having((e) => e.code, 'code', 'verify_failed'),
      ),
    );
    expect(await pending.keys(), [r.recordId]);
  });

  test('retryPending publishes leftovers and counts them', () async {
    final a = _rec(), b = _rec('2');
    await pending.put(a.recordId, a.encode());
    await pending.put(b.recordId, b.encode());
    await pending.put('junk', Uint8List.fromList([1, 2, 3]));
    expect(await publisher.retryPending(portfolioId: testPortfolioId), 2);
    expect(
      await folder.listRecordFiles(),
      unorderedEquals([a.fileName, b.fileName]),
    );
    expect(await pending.keys(), ['junk']);
  });
}
