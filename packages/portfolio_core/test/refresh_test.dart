import 'package:decimal/decimal.dart';
import 'package:portfolio_core/portfolio_core.dart';
import 'package:test/test.dart';

import 'helpers.dart';

class FakeSource implements PriceSource {
  FakeSource(this.id, this.assetClasses, {this.domains = const []});
  @override
  final String id;
  @override
  String get label => id;
  @override
  final List<String> domains;
  @override
  final Set<AssetClass> assetClasses;

  final List<String> calls = [];
  Object? failWith;
  List<PriceObservation> Function(Instrument, DateTime, DateTime)? closesFn;

  PriceObservation _o(Instrument i, DateTime d, PriceKind k) =>
      PriceObservation(
        instrumentId: i.id,
        price: Decimal.parse('10'),
        sessionDate: d,
        quoteTime: null,
        receivedAt: testNow,
        source: id,
        kind: k,
      );

  @override
  Future<List<PriceObservation>> latest(List<Instrument> instruments) async {
    calls.add('latest:${instruments.map((i) => i.id).join(',')}');
    if (failWith != null) throw failWith!;
    return [
      for (final i in instruments)
        _o(i, date(2026, 10, 10), PriceKind.delayedQuote),
    ];
  }

  @override
  Future<List<PriceObservation>> closes(
    Instrument instrument,
    DateTime from,
    DateTime to,
  ) async {
    calls.add('closes:${instrument.id}:${isoDate(from)}:${isoDate(to)}');
    if (failWith != null) throw failWith!;
    return closesFn?.call(instrument, from, to) ??
        [_o(instrument, to, PriceKind.close)];
  }
}

void main() {
  final bist = Instrument.create(AssetClass.bistShare, 'AAA');
  final btc = Instrument.create(AssetClass.crypto, 'BTC');
  final usd = Instrument.create(AssetClass.fx, 'USD');
  late DateTime now;
  late PriceStore store;
  late Set<String> enabled;
  late Map<String, FakeSource> src;
  late RefreshCoordinator rc;

  setUp(() {
    now = DateTime.utc(2026, 10, 10, 12);
    store = PriceStore(MemoryBlobStore());
    enabled = {};
    src = {
      'yahoo': FakeSource('yahoo', {AssetClass.bistShare, AssetClass.fx}),
      'isyatirim': FakeSource('isyatirim', {AssetClass.bistShare}),
      'tcmb': FakeSource('tcmb', {AssetClass.fx}),
      'btcturk': FakeSource('btcturk', {AssetClass.crypto}),
      'gold': FakeSource('gold', {AssetClass.gold}),
    };
    rc = RefreshCoordinator(
      sources: src.values.toList(),
      enabledSourceIds: () => enabled,
      store: store,
      nowUtc: () => now,
    );
  });

  int totalCalls() => src.values.fold(0, (n, s) => n + s.calls.length);

  test('no source enabled makes zero calls', () async {
    final r = await rc.refresh(
      current: [bist, btc],
      history: {
        date(2026, 10, 9): [bist, btc],
      },
    );
    expect(totalCalls(), 0);
    expect(r.fetched, 0);
    expect(rc.status, isEmpty);
  });

  test('only btcturk enabled: only btcturk is called', () async {
    enabled = {'btcturk'};
    final r = await rc.refresh(
      current: [bist, btc],
      history: {
        date(2026, 10, 9): [bist, btc],
      },
    );
    expect(src['btcturk']!.calls, [
      'latest:CRYPTO:BTC',
      'closes:CRYPTO:BTC:2026-09-29:2026-10-09',
    ]);
    expect(totalCalls(), 2);
    expect(r.fetched, 2);
    expect(rc.status['btcturk']!.lastSuccess, now);
  });

  test(
    'latest is batched once per source; fx prefers yahoo else tcmb',
    () async {
      enabled = {'yahoo', 'tcmb'};
      await rc.refresh(current: [bist, usd], history: {});
      expect(src['yahoo']!.calls, ['latest:XIST:AAA,FX:USD']);
      expect(src['tcmb']!.calls, isEmpty);

      enabled = {'tcmb'};
      now = now.add(const Duration(minutes: 6));
      await rc.refresh(current: [bist, usd], history: {});
      expect(src['tcmb']!.calls, ['latest:FX:USD']);
    },
  );

  test('history routes bist to isyatirim and fx to tcmb', () async {
    enabled = {'isyatirim', 'tcmb', 'yahoo'};
    await rc.refresh(
      current: [],
      history: {
        date(2026, 10, 9): [bist, usd],
      },
    );
    expect(src['isyatirim']!.calls, ['closes:XIST:AAA:2026-09-29:2026-10-09']);
    expect(src['tcmb']!.calls, ['closes:FX:USD:2026-09-29:2026-10-09']);
    expect(src['yahoo']!.calls, isEmpty);
  });

  test('second refresh within 5 minutes is skipped unless manual', () async {
    enabled = {'btcturk'};
    await rc.refresh(current: [btc], history: {});
    now = now.add(const Duration(minutes: 4));
    final r = await rc.refresh(
      current: [btc],
      history: {
        date(2026, 10, 1): [btc],
      },
    );
    expect(r.skippedNotDue, isTrue);
    expect(src['btcturk']!.calls, hasLength(1));
    final m = await rc.refresh(current: [btc], history: {}, manual: true);
    expect(m.skippedNotDue, isFalse);
    expect(src['btcturk']!.calls, hasLength(2));
    now = now.add(const Duration(minutes: 5));
    expect(
      (await rc.refresh(current: [btc], history: {})).skippedNotDue,
      isFalse,
    );
  });

  test(
    'error backs off, even for manual; doubles and caps at 60 min',
    () async {
      enabled = {'btcturk'};
      final s = src['btcturk']!..failWith = SourceException('btcturk', 'boom');
      var r = await rc.refresh(current: [btc], history: {});
      expect(r.errors, ['btcturk: boom']);
      expect(rc.status['btcturk']!.lastError, 'boom');
      expect(
        rc.status['btcturk']!.retryNotBefore,
        now.add(const Duration(minutes: 1)),
      );
      now = now.add(const Duration(seconds: 30));
      await rc.refresh(current: [btc], history: {}, manual: true);
      expect(s.calls, hasLength(1));
      now = now.add(const Duration(minutes: 1));
      await rc.refresh(current: [btc], history: {}, manual: true);
      expect(s.calls, hasLength(2));
      expect(
        rc.status['btcturk']!.retryNotBefore,
        now.add(const Duration(minutes: 2)),
      );
      for (var i = 0; i < 10; i++) {
        now = rc.status['btcturk']!.retryNotBefore!;
        await rc.refresh(current: [btc], history: {}, manual: true);
      }
      expect(
        rc.status['btcturk']!.retryNotBefore,
        now.add(const Duration(minutes: 60)),
      );
      // success resets
      s.failWith = null;
      now = rc.status['btcturk']!.retryNotBefore!;
      await rc.refresh(current: [btc], history: {}, manual: true);
      expect(rc.status['btcturk']!.retryNotBefore, isNull);
      expect(rc.status['btcturk']!.lastError, isNull);
    },
  );

  test('retryAfter overrides backoff', () async {
    enabled = {'btcturk'};
    src['btcturk']!.failWith = SourceException(
      'btcturk',
      'Rate limited (429)',
      retryAfter: const Duration(minutes: 7),
    );
    await rc.refresh(current: [btc], history: {});
    expect(
      rc.status['btcturk']!.retryNotBefore,
      now.add(const Duration(minutes: 7)),
    );
  });

  test('consent denied is not an error or backoff; others continue', () async {
    enabled = {'btcturk', 'gold'};
    src['btcturk']!.failWith = ConsentDeniedException('x.example');
    final g = Instrument.create(AssetClass.gold, 'GRAM');
    final r = await rc.refresh(current: [btc, g], history: {});
    expect(r.errors, isEmpty);
    expect(rc.status['btcturk']!.lastError, 'Source is disabled');
    expect(rc.status['btcturk']!.retryNotBefore, isNull);
    expect(src['gold']!.calls, ['latest:GOLD:GRAM']);
    expect(r.fetched, 1);
  });

  test('unexpected exception is recorded by type only and backs off', () async {
    enabled = {'btcturk', 'gold'};
    src['btcturk']!.failWith = StateError('https://secret.example/body');
    final g = Instrument.create(AssetClass.gold, 'GRAM');
    final r = await rc.refresh(current: [btc, g], history: {});
    expect(r.errors, ['btcturk: StateError']);
    expect(rc.status['btcturk']!.lastError, 'StateError');
    expect(rc.status['btcturk']!.retryNotBefore, isNotNull);
    expect(src['gold']!.calls, hasLength(1));
  });

  test(
    'exact-date cached close means no history call; an older one does not',
    () async {
      enabled = {'isyatirim'};
      await store.addFetched([obs('XIST:AAA', '5', date(2026, 10, 9))]);
      await rc.refresh(
        current: [],
        history: {
          date(2026, 10, 9): [bist],
        },
      );
      expect(totalCalls(), 0);
      await rc.refresh(
        current: [],
        history: {
          date(2026, 10, 12): [bist],
        },
        manual: true,
      );
      expect(src['isyatirim']!.calls, [
        'closes:XIST:AAA:2026-10-02:2026-10-12',
      ]);
    },
  );

  test('a window fetched earlier covers its dates, and only those', () async {
    enabled = {'isyatirim'};
    final s = src['isyatirim']!..closesFn = (_, _, _) => [];
    Future<void> need(DateTime d) => rc.refresh(
      current: [],
      history: {
        d: [bist],
      },
      manual: true,
    );
    await need(date(2026, 10, 4));
    await need(date(2026, 10, 4));
    await need(date(2026, 9, 24));
    expect(s.calls, ['closes:XIST:AAA:2026-09-24:2026-10-04']);
    await need(date(2026, 9, 20));
    await need(date(2026, 10, 5));
    expect(s.calls, hasLength(3));
  });

  test(
    'Daily follows new sessions day by day (Thu 10-01 → Tue 10-06)',
    () async {
      enabled = {'isyatirim', 'yahoo'};
      final txs = [buy(on: date(2026, 9, 1))];
      // The source knows a close for every weekday before the current day.
      src['isyatirim']!.closesFn = (i, from, to) => [
        for (var d = from; !d.isAfter(to); d = d.add(const Duration(days: 1)))
          if (d.weekday <= DateTime.friday && d.isBefore(istanbulToday(now)))
            obs(i.id, '${d.month}${d.day.toString().padLeft(2, '0')}', d),
      ];
      final expected = {
        1: date(2026, 9, 30),
        2: date(2026, 10, 1),
        3: date(2026, 10, 2),
        4: date(2026, 10, 2),
        5: date(2026, 10, 2),
        6: date(2026, 10, 5),
      };
      for (final e in expected.entries) {
        now = DateTime.utc(2026, 10, e.key, 9);
        final today = istanbulToday(now);
        await rc.refresh(
          current: [bist],
          history: historicalPriceNeeds(
            today: today,
            transactions: txs,
            calendar: TradingCalendar(store.knownBistTradingDays()),
          ),
        );
        final r = computePeriod(
          period: Period.daily,
          today: today,
          transactions: txs,
          prices: store,
          calendar: TradingCalendar(store.knownBistTradingDays()),
        );
        final b = e.value;
        expect(r.baseline, b, reason: 'baseline on ${isoDate(today)}');
        expect(
          r.valueStart,
          Decimal.parse('${b.month}${b.day.toString().padLeft(2, '0')}'),
          reason: 'close used on ${isoDate(today)}',
        );
      }
    },
  );

  test('hostsFor is the union of domains', () {
    final a = FakeSource('a', {}, domains: ['x.example', 'y.example']);
    final b = FakeSource('b', {}, domains: ['y.example', 'z.example']);
    expect(RefreshCoordinator.hostsFor([a, b]), {
      'x.example',
      'y.example',
      'z.example',
    });
    expect(RefreshCoordinator.hostsFor([]), isEmpty);
  });
}
