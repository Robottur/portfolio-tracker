import 'dart:convert';
import 'dart:typed_data';

import 'package:portfolio_core/portfolio_core.dart';
import 'package:test/test.dart';

import 'helpers.dart';

const pid = '11111111-1111-4111-8111-111111111111';
const dev = '22222222-2222-4222-8222-222222222222';
final now = DateTime.utc(2026, 10, 10, 12);

LedgerRecord upsert() => LedgerRecord.newUpsert(
  portfolioId: pid,
  deviceId: dev,
  transaction: buy(on: DateTime.utc(2026, 10, 1), qty: '2.5', price: '10'),
  now: now,
);

Map<String, Object?> json(LedgerRecord r) =>
    jsonDecode(utf8.decode(r.encode())) as Map<String, Object?>;

Uint8List bytes(Object? j) => Uint8List.fromList(utf8.encode(jsonEncode(j)));

void expectCode(Uint8List b, String code, {String portfolio = pid}) {
  expect(
    () => LedgerRecord.decode(b, portfolioId: portfolio),
    throwsA(isA<RecordFormatException>().having((e) => e.code, 'code', code)),
  );
}

void main() {
  test('round trip and key order', () {
    final r = upsert();
    final back = LedgerRecord.decode(r.encode(), portfolioId: pid);
    expect(back.sameContentAs(r), isTrue);
    expect(back.createdAt, now);
    expect(json(r).keys.toList(), [
      'schema_version',
      'portfolio_id',
      'record_id',
      'transaction_id',
      'supersedes',
      'operation',
      'created_at',
      'device_id',
      'transaction',
    ]);
    expect(json(r)['created_at'], '2026-10-10T12:00:00Z');
    expect(utf8.decode(r.encode()), contains('\n  "schema_version": 1'));
    expect(r.fileName, '${r.recordId}.json');
  });

  test('void round trip', () {
    final v = LedgerRecord.newVoid(
      portfolioId: pid,
      deviceId: dev,
      transactionId: upsert().transactionId,
      supersedes: [upsert().recordId],
      now: now,
    );
    final back = LedgerRecord.decode(v.encode(), portfolioId: pid);
    expect(back.operation, RecordOp.voided);
    expect(back.transaction, isNull);
    expect(back.sameContentAs(v), isTrue);
  });

  test('sameContentAs ignores key order and whitespace', () {
    final r = upsert();
    final m = json(r);
    final reordered = Map.fromEntries(m.entries.toList().reversed);
    final other = LedgerRecord.decode(
      Uint8List.fromList(
        utf8.encode(const JsonEncoder.withIndent('    ').convert(reordered)),
      ),
      portfolioId: pid,
    );
    expect(other.sameContentAs(r), isTrue);
  });

  test('sameContentAs false when content differs', () {
    expect(upsert().sameContentAs(upsert()), isFalse); // new ids
  });

  test('too large', () {
    expectCode(Uint8List(65537), 'too_large');
  });

  test('bad json: duplicate key, garbage, bad utf8, BOM', () {
    expectCode(Uint8List.fromList(utf8.encode('{"a":1,"a":2}')), 'bad_json');
    expectCode(Uint8List.fromList(utf8.encode('nope')), 'bad_json');
    expectCode(Uint8List.fromList([0xff, 0xfe, 0x41]), 'bad_json');
    final withBom = Uint8List.fromList([
      0xef,
      0xbb,
      0xbf,
      ...upsert().encode(),
    ]);
    expect(
      () => LedgerRecord.decode(withBom, portfolioId: pid),
      throwsA(
        isA<RecordFormatException>().having(
          (e) => e.message,
          'message',
          'file starts with a byte-order mark',
        ),
      ),
    );
  });

  test('bad json message never contains file content', () {
    try {
      LedgerRecord.decode(
        Uint8List.fromList(utf8.encode('{"secret_marker": x}')),
        portfolioId: pid,
      );
      fail('expected throw');
    } on RecordFormatException catch (e) {
      expect(e.message, isNot(contains('secret_marker')));
    }
  });

  test('unsupported version is reported before other field errors', () {
    final m = json(upsert())
      ..['schema_version'] = 2
      ..remove('device_id');
    expectCode(bytes(m), 'unsupported_version');
  });

  test('wrong portfolio', () {
    expectCode(
      upsert().encode(),
      'wrong_portfolio',
      portfolio: '33333333-3333-4333-8333-333333333333',
    );
  });

  group('invalid_field', () {
    void bad(String name, void Function(Map<String, Object?>) mutate) {
      test(name, () {
        final m = json(upsert());
        mutate(m);
        expectCode(bytes(m), 'invalid_field');
      });
    }

    bad('created_at without Z', (m) => m['created_at'] = '2026-10-10T12:00:00');
    bad(
      'created_at with offset',
      (m) => m['created_at'] = '2026-10-10T12:00:00+03:00',
    );
    bad('VOID with transaction', (m) => m['operation'] = 'VOID');
    bad('UPSERT without transaction', (m) => m['transaction'] = null);
    bad('unknown operation', (m) => m['operation'] = 'DELETE');
    bad('supersedes not uuid', (m) => m['supersedes'] = ['nope']);
    bad('supersedes not list', (m) => m['supersedes'] = 'x');
    bad(
      'uppercase uuid',
      (m) => m['record_id'] = (m['record_id'] as String).toUpperCase(),
    );
    bad('device_id not uuid', (m) => m['device_id'] = 'dev');
    bad(
      'currency not TRY',
      (m) => (m['transaction'] as Map)['currency'] = 'USD',
    );
    bad('missing field', (m) => m.remove('transaction_id'));
  });

  test('isUuid', () {
    expect(isUuid(pid), isTrue);
    expect(isUuid('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'), isTrue);
    expect(isUuid('AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA'), isFalse);
    expect(isUuid('abc'), isFalse);
  });

  group('PortfolioDescriptor', () {
    test('round trip', () {
      final d = PortfolioDescriptor.create('  Main  ');
      expect(d.name, 'Main');
      final back = PortfolioDescriptor.decode(d.encode());
      expect(back.portfolioId, d.portfolioId);
      expect(back.name, 'Main');
      expect((jsonDecode(utf8.decode(d.encode())) as Map).keys.toList(), [
        'schema_version',
        'portfolio_id',
        'name',
        'currency',
        'reporting_timezone',
      ]);
    });

    test('rejects bad values', () {
      final good = jsonDecode(
        utf8.decode(PortfolioDescriptor.create('x').encode()),
      ) as Map<String, Object?>;
      for (final mutate in <void Function(Map<String, Object?>)>[
        (m) => m['schema_version'] = 2,
        (m) => m['currency'] = 'USD',
        (m) => m['reporting_timezone'] = 'UTC',
        (m) => m['name'] = '   ',
        (m) => m['name'] = 'a' * 201,
        (m) => m['portfolio_id'] = 'x',
      ]) {
        final m = Map<String, Object?>.of(good);
        mutate(m);
        expect(
          () => PortfolioDescriptor.decode(bytes(m)),
          throwsA(isA<RecordFormatException>()),
        );
      }
      expect(
        () => PortfolioDescriptor.decode(Uint8List.fromList(utf8.encode('{'))),
        throwsA(isA<RecordFormatException>()),
      );
      expect(() => PortfolioDescriptor.create(' '), throwsArgumentError);
    });
  });
}
