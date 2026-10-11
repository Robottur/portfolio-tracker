import 'dart:convert';
import 'dart:typed_data';

import 'package:decimal/decimal.dart';
import 'package:portfolio_core/portfolio_core.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  late MemoryBlobStore blobs;
  late PriceStore store;
  setUp(() {
    blobs = MemoryBlobStore();
    store = PriceStore(blobs);
  });

  test('persists across a new store on the same blobs', () async {
    await store.addFetched([obs('XIST:AAA', '10.5', date(2026, 10, 9))]);
    await store.setManual(
      'XIST:AAA',
      date(2026, 10, 8),
      Decimal.parse('9'),
      nowUtc: testNow,
    );
    final again = PriceStore(blobs);
    await again.load();
    expect(
      again.closeOnOrBefore('XIST:AAA', date(2026, 10, 9))!.price,
      Decimal.parse('10.5'),
    );
    expect(
      again.closeOnOrBefore('XIST:AAA', date(2026, 10, 8))!.kind,
      PriceKind.manual,
    );
  });

  test('json round trip keeps fields', () {
    final o = obs(
      'X:A',
      '1.25',
      date(2026, 1, 2),
      kind: PriceKind.delayedQuote,
      quoteTime: DateTime.utc(2026, 1, 2, 9),
    );
    final back = PriceObservation.fromJson(
      jsonDecode(jsonEncode(o.toJson())) as Object?,
    );
    expect(back.toJson(), o.toJson());
    expect(back.quoteTime, DateTime.utc(2026, 1, 2, 9));
  });

  test('nonpositive prices are skipped', () async {
    await store.addFetched([
      obs('XIST:AAA', '0', date(2026, 10, 9)),
      obs('XIST:AAA', '-1', date(2026, 10, 8)),
    ]);
    expect(store.latest('XIST:AAA'), isNull);
  });

  test('newer receivedAt replaces same instrument/date/kind', () async {
    await store.addFetched([obs('XIST:AAA', '1', date(2026, 10, 9))]);
    await store.addFetched([
      obs(
        'XIST:AAA',
        '2',
        date(2026, 10, 9),
        receivedAt: testNow.add(const Duration(hours: 1)),
      ),
      obs(
        'XIST:AAA',
        '3',
        date(2026, 10, 9),
        receivedAt: testNow.subtract(const Duration(hours: 1)),
      ),
    ]);
    expect(store.latest('XIST:AAA')!.price, Decimal.parse('2'));
  });

  test('close lookup on Sunday returns Friday close', () async {
    await store.addFetched([
      obs('XIST:AAA', '10', date(2026, 10, 9)),
      obs('XIST:AAA', '11', date(2026, 10, 12)),
    ]);
    expect(
      store.closeOnOrBefore('XIST:AAA', date(2026, 10, 11))!.price,
      Decimal.parse('10'),
    );
    expect(store.closeOnOrBefore('XIST:AAA', date(2026, 10, 1)), isNull);
  });

  test('manual beats fetched on same date; removal restores', () async {
    await store.addFetched([obs('XIST:AAA', '10', date(2026, 10, 9))]);
    await store.setManual(
      'XIST:AAA',
      date(2026, 10, 9),
      Decimal.parse('12'),
      nowUtc: testNow,
    );
    expect(
      store.closeOnOrBefore('XIST:AAA', date(2026, 10, 9))!.price,
      Decimal.parse('12'),
    );
    await store.setManual(
      'XIST:AAA',
      date(2026, 10, 9),
      Decimal.parse('13'),
      nowUtc: testNow,
    );
    expect(store.latest('XIST:AAA')!.price, Decimal.parse('13'));
    await store.removeManual('XIST:AAA', date(2026, 10, 9));
    expect(store.latest('XIST:AAA')!.price, Decimal.parse('10'));
  });

  test('latest prefers later quote time, then manual on ties', () async {
    await store.addFetched([
      obs('C:B', '1', date(2026, 10, 9)),
      obs(
        'C:B',
        '2',
        date(2026, 10, 9),
        kind: PriceKind.delayedQuote,
        quoteTime: DateTime.utc(2026, 10, 9, 10),
      ),
    ]);
    // a close counts as end of day, so it is newer than a 10:00 quote
    expect(store.latest('C:B')!.price, Decimal.parse('1'));
    await store.addFetched([
      obs(
        'C:B',
        '3',
        date(2026, 10, 9),
        kind: PriceKind.delayedQuote,
        quoteTime: DateTime.utc(2026, 10, 10),
      ),
    ]);
    await store.setManual(
      'C:B',
      date(2026, 10, 9),
      Decimal.parse('4'),
      nowUtc: testNow,
    );
    // quote at 00:00 next day equals the close's end of day: manual wins the tie
    expect(store.latest('C:B')!.price, Decimal.parse('4'));
  });

  test('known BIST trading days are distinct XIST closes', () async {
    await store.addFetched([
      obs('XIST:AAA', '1', date(2026, 10, 9)),
      obs('XIST:BBB', '1', date(2026, 10, 9)),
      obs('XIST:AAA', '1', date(2026, 10, 8)),
      obs('CRYPTO:BTC', '1', date(2026, 10, 10)),
    ]);
    expect(store.knownBistTradingDays(), [
      date(2026, 10, 8),
      date(2026, 10, 9),
    ]);
  });

  test('corrupt cache is skipped, never a price', () async {
    blobs.data['prices'] = Uint8List.fromList(utf8.encode('not json'));
    blobs.data['manual'] = Uint8List.fromList(
      utf8.encode(
        jsonEncode([
          obs('XIST:AAA', '5', date(2026, 10, 9)).toJson(),
          {...obs('XIST:BBB', '5', date(2026, 10, 9)).toJson(), 'price': '0'},
          {...obs('XIST:CCC', '5', date(2026, 10, 9)).toJson(), 'kind': 'x'},
          {
            ...obs('XIST:DDD', '5', date(2026, 10, 9)).toJson(),
            'received_at': 5,
          },
          'junk',
        ]),
      ),
    );
    await store.load();
    expect(store.latest('XIST:AAA')!.price, Decimal.parse('5'));
    for (final id in ['XIST:BBB', 'XIST:CCC', 'XIST:DDD']) {
      expect(store.latest(id), isNull);
    }
  });

  test('high-precision prices survive a reload', () async {
    final derived = divide(
      Decimal.parse('4216.3') * Decimal.parse('49.26'),
      Decimal.parse('31.1034768'),
    );
    await store.addFetched([
      obs(
        'C:GOLD',
        derived.toString(),
        date(2026, 10, 9),
        kind: PriceKind.derived,
      ),
    ]);
    await store.setManual(
      'C:TINY',
      date(2026, 10, 9),
      Decimal.parse('0.000000001234'),
      nowUtc: testNow,
    );
    final again = PriceStore(blobs);
    await again.load();
    expect(again.latest('C:GOLD')!.price, derived);
    expect(again.closeOnOrBefore('C:GOLD', date(2026, 10, 9))!.price, derived);
    expect(again.latest('C:TINY')!.price, Decimal.parse('0.000000001234'));
  });

  test('manual price that could not reload is rejected', () {
    for (final p in ['0', '1' * 19, '0.${'1' * 29}']) {
      expect(
        () => store.setManual(
          'C:TINY',
          date(2026, 10, 9),
          Decimal.parse(p),
          nowUtc: testNow,
        ),
        throwsArgumentError,
      );
    }
  });

  test('manualPrices lists only manual entries, sorted', () async {
    await store.addFetched([obs('XIST:AAA', '10', date(2026, 10, 9))]);
    await store.setManual(
      'XIST:BBB',
      date(2026, 10, 8),
      Decimal.one,
      nowUtc: testNow,
    );
    await store.setManual(
      'XIST:AAA',
      date(2026, 10, 9),
      Decimal.parse('2'),
      nowUtc: testNow,
    );
    expect(
      [for (final o in store.manualPrices) o.instrumentId],
      ['XIST:AAA', 'XIST:BBB'],
    );
  });

  test('fund kinds persist; a corrupt blob is ignored', () async {
    await store.setFundKind('TTE', 'EMK');
    final again = PriceStore(blobs);
    await again.load();
    expect(again.fundKind('TTE'), 'EMK');
    await blobs.put('fund_kinds', Uint8List.fromList(utf8.encode('{nope')));
    final bad = PriceStore(blobs);
    await bad.load();
    expect(bad.fundKind('TTE'), isNull);
  });
}
