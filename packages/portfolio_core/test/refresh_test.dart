import 'dart:convert';
import 'dart:io';

import 'package:decimal/decimal.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:portfolio_core/portfolio_core.dart';
import 'package:test/test.dart';

import 'helpers.dart';

class FakeInflation implements InflationSource {
  FakeInflation(this.id, this.months, {this.fail = false});
  @override
  final String id;
  final Map<String, Decimal> months;
  bool fail;
  int calls = 0;
  @override
  String get label => id;
  @override
  List<String> get domains => const [];
  @override
  Set<AssetClass> get assetClasses => const {};
  @override
  Future<List<PriceObservation>> latest(List<Instrument> i) async => [];
  @override
  Future<List<PriceObservation>> closes(
    Instrument i,
    DateTime a,
    DateTime b,
  ) async => [];
  @override
  Future<Map<String, Decimal>> monthly(DateTime from) async {
    calls++;
    if (fail) throw SourceException(id, 'boom');
    return months;
  }
}

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
  List<Instrument> Function(List<Instrument>)? latestFn;

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
      for (final i in latestFn?.call(instruments) ?? instruments)
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
      'binance': FakeSource('binance', {AssetClass.crypto}),
      'gold': FakeSource('gold', {AssetClass.gold}),
    };
    rc = RefreshCoordinator(
      sources: src.values.toList(),
      enabledSourceIds: () => enabled,
      store: store,
      nowUtc: () => now,
    );
  });

  test('routing helpers', () {
    expect(RefreshCoordinator.latestSourceId(AssetClass.fund, {}), 'tefas');
    expect(RefreshCoordinator.closesSourceId(AssetClass.fund, {}), 'tefas');
    expect(
      RefreshCoordinator.closesSourceId(AssetClass.fx, {'yahoo'}),
      'yahoo',
    );
    expect(RefreshCoordinator.closesSourceId(AssetClass.fx, {'tcmb'}), 'tcmb');
    expect(RefreshCoordinator.latestSourceId(AssetClass.fx, {'tcmb'}), 'tcmb');
    expect(
      RefreshCoordinator.latestSourceId(AssetClass.fx, {'yahoo'}),
      'yahoo',
    );
  });

  test(
    'fund holding with only tefas enabled calls only tefas latest',
    () async {
      final fund = Instrument.create(AssetClass.fund, 'TTE');
      final tefas = FakeSource('tefas', {AssetClass.fund});
      final r = RefreshCoordinator(
        sources: [...src.values, tefas],
        enabledSourceIds: () => {'tefas'},
        store: store,
        nowUtc: () => now,
      );
      await r.refresh(current: [fund], history: {});
      expect(tefas.calls, ['latest:${fund.id}']);
      expect(src.values.fold(0, (n, s) => n + s.calls.length), 0);
    },
  );

  group('tefas per-fund latest', () {
    final funds = [
      for (final c in ['AAA', 'BBB', 'CCC', 'DDD', 'EEE', 'FFF', 'GGG'])
        Instrument.create(AssetClass.fund, c),
    ];
    RefreshCoordinator make(PriceSource tefas) => RefreshCoordinator(
      sources: [tefas],
      enabledSourceIds: () => {'tefas'},
      store: store,
      nowUtc: () => now,
    );

    test('stores what it got before a 429 and then backs off', () async {
      var requests = 0;
      final tefas = TefasSource(
        MockClient((req) async {
          requests++;
          if (requests > 6) {
            return http.Response('', 429, headers: {'retry-after': '60'});
          }
          final code = (jsonDecode(req.body) as Map)['fonKodu'] as String;
          return http.Response(
            jsonEncode({
              'errorMessage': null,
              'resultList': [
                {'fonKodu': code, 'tarih': '2026-10-09', 'fiyat': 1.5},
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
        nowUtc: () => now,
      );
      final r = make(tefas);
      final rep = await r.refresh(current: funds, history: {});
      expect(requests, 7);
      expect(rep.fetched, 6);
      expect(store.latest(funds.first.id), isNotNull);
      expect(store.latest(funds.last.id), isNull);
      expect(
        r.status['tefas']!.retryNotBefore,
        now.add(const Duration(seconds: 60)),
      );
      now = now.add(const Duration(seconds: 30));
      await r.refresh(current: funds, history: {}, manual: true);
      expect(requests, 7);
    });

    test('an outage is one failure per refresh, not one per fund', () async {
      var requests = 0;
      final tefas = TefasSource(
        MockClient((_) async {
          requests++;
          return http.Response('', 500);
        }),
        nowUtc: () => now,
      );
      final r = make(tefas);
      await r.refresh(current: funds, history: {});
      expect(requests, 1);
      expect(
        r.status['tefas']!.retryNotBefore,
        now.add(const Duration(minutes: 1)),
      );
    });

    test('latest caches every row for later closes', () async {
      var requests = 0;
      final body = File('test/fixtures/tefas_tte_yat.json').readAsStringSync();
      final tefas = TefasSource(
        MockClient((_) async {
          requests++;
          return http.Response(
            body,
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
        nowUtc: () => now,
      );
      final tte = Instrument.create(AssetClass.fund, 'TTE');
      await make(tefas).refresh(current: [tte], history: {});
      expect(requests, 1);
      expect(
        store.closeOnOrBefore(tte.id, date(2026, 10, 5))?.sessionDate,
        date(2026, 10, 5),
      );
    });
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

  group('binance fallback', () {
    final bnb = Instrument.create(AssetClass.crypto, 'BNB');
    setUp(() {
      // BtcTurk lists BTC only.
      src['btcturk']!.latestFn = (l) => l.where((i) => i.id == btc.id).toList();
      src['btcturk']!.closesFn = (i, f, t) =>
          i.id == btc.id ? [src['btcturk']!._o(i, t, PriceKind.close)] : [];
    });

    test('routing helpers', () {
      expect(
        RefreshCoordinator.latestSourceId(AssetClass.crypto, {'btcturk'}),
        'btcturk',
      );
      expect(
        RefreshCoordinator.latestSourceId(AssetClass.crypto, {'binance'}),
        'binance',
      );
      expect(
        RefreshCoordinator.closesSourceId(AssetClass.crypto, {'binance'}),
        'binance',
      );
    });

    test('coin btcturk lacks goes to binance', () async {
      enabled = {'btcturk', 'binance'};
      await rc.refresh(current: [btc, bnb], history: {});
      expect(src['btcturk']!.calls, ['latest:CRYPTO:BTC,CRYPTO:BNB']);
      expect(src['binance']!.calls, ['latest:CRYPTO:BNB']);
      expect(store.latest(bnb.id)?.source, 'binance');
    });

    test('binance off: no fallback request', () async {
      enabled = {'btcturk'};
      await rc.refresh(current: [btc, bnb], history: {});
      expect(src['binance']!.calls, isEmpty);
      expect(store.latest(bnb.id), isNull);
    });

    test('only binance enabled takes all crypto', () async {
      enabled = {'binance'};
      await rc.refresh(current: [btc, bnb], history: {});
      expect(src['btcturk']!.calls, isEmpty);
      expect(src['binance']!.calls, ['latest:CRYPTO:BTC,CRYPTO:BNB']);
    });

    test('btcturk in backoff: crypto goes to binance', () async {
      enabled = {'btcturk', 'binance'};
      src['btcturk']!.failWith = SourceException('btcturk', 'boom');
      await rc.refresh(current: [btc], history: {});
      src['btcturk']!.failWith = null;
      await rc.refresh(current: [btc], history: {}, manual: true);
      expect(src['binance']!.calls, ['latest:CRYPTO:BTC']);
    });

    test('closes: empty from btcturk falls back to binance', () async {
      enabled = {'btcturk', 'binance'};
      final d = date(2026, 10, 9);
      await rc.refresh(
        current: [],
        history: {
          d: [btc, bnb],
        },
      );
      expect(src['btcturk']!.calls, [
        'closes:CRYPTO:BTC:2026-09-29:2026-10-09',
        'closes:CRYPTO:BNB:2026-09-29:2026-10-09',
      ]);
      expect(src['binance']!.calls, [
        'closes:CRYPTO:BNB:2026-09-29:2026-10-09',
      ]);
    });

    test('closes: binance off, no fallback request', () async {
      enabled = {'btcturk'};
      await rc.refresh(
        current: [],
        history: {
          date(2026, 10, 9): [bnb],
        },
      );
      expect(src['binance']!.calls, isEmpty);
    });
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

  test(
    'history routes bist to isyatirim and fx to yahoo when enabled',
    () async {
      enabled = {'isyatirim', 'tcmb', 'yahoo'};
      await rc.refresh(
        current: [],
        history: {
          date(2026, 10, 9): [bist, usd],
        },
      );
      expect(src['isyatirim']!.calls, [
        'closes:XIST:AAA:2026-09-29:2026-10-09',
      ]);
      expect(src['yahoo']!.calls, ['closes:FX:USD:2026-09-29:2026-10-09']);
      expect(src['tcmb']!.calls, isEmpty);
    },
  );

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

  group('fetchOnce', () {
    test('a 429 from it blocks the next refresh and the next fetch', () async {
      final src = FakeSource('yahoo', {AssetClass.bistShare});
      var now = testNow;
      final rc = RefreshCoordinator(
        sources: [src],
        enabledSourceIds: () => {'yahoo'},
        store: PriceStore(MemoryBlobStore()),
        nowUtc: () => now,
      );
      final i = Instrument.create(AssetClass.bistShare, 'THYAO');
      await expectLater(
        rc.fetchOnce(
          src,
          () async => throw SourceException(
            'yahoo',
            'Rate limited (429)',
            retryAfter: const Duration(seconds: 60),
          ),
        ),
        throwsA(isA<SourceException>()),
      );
      await rc.refresh(current: [i], history: {}, manual: true);
      expect(src.calls, isEmpty);
      await expectLater(
        rc.fetchOnce(src, () => src.latest([i])),
        throwsA(
          isA<SourceException>().having(
            (e) => e.message,
            'message',
            'Rate limited; try again after 15:01',
          ),
        ),
      );
      expect(src.calls, isEmpty);
      now = testNow.add(const Duration(seconds: 61));
      expect(await rc.fetchOnce(src, () => src.latest([i])), hasLength(1));
    });

    test('a back-off set by refresh blocks it', () async {
      final src = FakeSource('yahoo', {AssetClass.bistShare})
        ..failWith = SourceException(
          'yahoo',
          'x',
          retryAfter: const Duration(minutes: 5),
        );
      final rc = RefreshCoordinator(
        sources: [src],
        enabledSourceIds: () => {'yahoo'},
        store: PriceStore(MemoryBlobStore()),
        nowUtc: () => testNow,
      );
      final i = Instrument.create(AssetClass.bistShare, 'THYAO');
      await rc.refresh(current: [i], history: {}, manual: true);
      src.calls.clear();
      await expectLater(
        rc.fetchOnce(src, () => src.latest([i])),
        throwsA(isA<SourceException>()),
      );
      expect(src.calls, isEmpty);
    });
  });

  test('usd dates with yahoo make one range request', () async {
    enabled = {'yahoo'};
    final dates = {date(2026, 1, 5), date(2026, 3, 2)};
    await rc.refresh(current: [], history: {}, usdDates: dates);
    expect(src['yahoo']!.calls, ['closes:FX:USD:2025-12-26:2026-03-02']);
    await rc.refresh(current: [], history: {}, usdDates: dates, manual: true);
    expect(src['yahoo']!.calls, hasLength(1));
  });

  test('usd dates with tcmb make one request per date', () async {
    enabled = {'tcmb'};
    await rc.refresh(
      current: [],
      history: {},
      usdDates: {date(2026, 1, 5), date(2026, 3, 2)},
    );
    expect(src['tcmb']!.calls, [
      'closes:FX:USD:2025-12-26:2026-01-05',
      'closes:FX:USD:2026-02-20:2026-03-02',
    ]);
  });

  group('refreshInflation', () {
    late FakeInflation evds, tcmb;
    late RefreshCoordinator irc;
    setUp(() {
      evds = FakeInflation('evds', {'2026-08': Decimal.parse('1.9')});
      tcmb = FakeInflation('tcmbcpi', {'2026-08': Decimal.parse('1.84')});
      irc = RefreshCoordinator(
        sources: [evds, tcmb],
        enabledSourceIds: () => enabled,
        store: store,
        nowUtc: () => now,
      );
    });

    test('evds first, tcmb when evds fails', () async {
      enabled = {'evds', 'tcmbcpi'};
      evds.fail = true;
      expect(await irc.refreshInflation(from: date(2026, 1, 1)), 'tcmbcpi');
      expect(store.cpi.months['2026-08']!.source, 'tcmb');
      expect(irc.status['evds']!.lastError, 'boom');
      expect(irc.status['evds']!.retryNotBefore, isNotNull);
    });

    test('evds wins when it works', () async {
      enabled = {'evds', 'tcmbcpi'};
      expect(await irc.refreshInflation(from: date(2026, 1, 1)), 'evds');
      expect(store.cpi.months['2026-08']!.source, 'evds');
      expect(tcmb.calls, 0);
    });

    test('once per day, manual bypasses', () async {
      enabled = {'tcmbcpi'};
      await irc.refreshInflation(from: date(2026, 1, 1));
      expect(await irc.refreshInflation(from: date(2026, 1, 1)), isNull);
      expect(tcmb.calls, 1);
      now = now.add(const Duration(hours: 1));
      expect(await irc.refreshInflation(from: date(2026, 1, 1)), isNull);
      expect(
        await irc.refreshInflation(from: date(2026, 1, 1), manual: true),
        'tcmbcpi',
      );
      expect(tcmb.calls, 2);
      now = now.add(const Duration(days: 1));
      expect(await irc.refreshInflation(from: date(2026, 1, 1)), 'tcmbcpi');
    });

    test('nothing enabled: no call, day not used', () async {
      expect(await irc.refreshInflation(from: date(2026, 1, 1)), isNull);
      enabled = {'tcmbcpi'};
      expect(await irc.refreshInflation(from: date(2026, 1, 1)), 'tcmbcpi');
    });

    test('evds without a key is not configured, not a failure', () async {
      var key = '';
      var requests = 0;
      final ev = EvdsSource(
        MockClient((_) async {
          requests++;
          return http.Response(
            '{"items":[{"Tarih":"2026-7","TP_FG_J0":"100"},'
            '{"Tarih":"2026-8","TP_FG_J0":"101.84"}]}',
            200,
          );
        }),
        key: () => key,
        nowUtc: () => now,
      );
      final r = RefreshCoordinator(
        sources: [ev, tcmb],
        enabledSourceIds: () => {'evds', 'tcmbcpi'},
        store: store,
        nowUtc: () => now,
      );
      expect(await r.refreshInflation(from: date(2026, 1, 1)), 'tcmbcpi');
      expect(requests, 0);
      expect(r.status['evds']!.retryNotBefore, isNull);
      expect(r.status['evds']!.lastError, 'Add your EVDS key in Settings');
      key = 'abc';
      expect(
        await r.refreshInflation(from: date(2026, 1, 1), manual: true),
        'evds',
      );
      expect(requests, 1);
      expect(store.cpi.months['2026-08']!.source, 'evds');
    });

    test('failures do not use up the day', () async {
      enabled = {'tcmbcpi'};
      tcmb.fail = true;
      expect(await irc.refreshInflation(from: date(2026, 1, 1)), isNull);
      expect(await irc.refreshInflation(from: date(2026, 1, 1)), isNull);
      expect(tcmb.calls, 1); // still in back-off
      now = now.add(const Duration(minutes: 2));
      tcmb.fail = false;
      expect(await irc.refreshInflation(from: date(2026, 1, 1)), 'tcmbcpi');
      expect(tcmb.calls, 2);
      expect(await irc.refreshInflation(from: date(2026, 1, 1)), isNull);
      expect(tcmb.calls, 2);
    });

    test('changed page keeps stored months', () async {
      await store.setCpi({'2026-07': Decimal.parse('1.78')}, 'tcmb');
      final page = File('test/fixtures/tcmb_cpi_page.html')
          .readAsStringSync()
          .replaceFirst('Ay-Yıl', 'Ay-Yil');
      final r = RefreshCoordinator(
        sources: [
          TcmbCpiSource(
            MockClient(
              (_) async => http.Response.bytes(utf8.encode(page), 200),
            ),
          ),
        ],
        enabledSourceIds: () => {'tcmbcpi'},
        store: store,
        nowUtc: () => now,
      );
      expect(await r.refreshInflation(from: date(2026, 1, 1)), isNull);
      expect(r.status['tcmbcpi']!.lastError, contains('page changed'));
      expect(store.cpi.months.keys, ['2026-07']);
    });

    test('percent at or below -100 is a source error', () async {
      enabled = {'tcmbcpi'};
      tcmb.months['2026-08'] = Decimal.parse('-100');
      expect(await irc.refreshInflation(from: date(2026, 1, 1)), isNull);
      expect(irc.status['tcmbcpi']!.lastError, 'Unusable inflation value');
    });
  });
}
