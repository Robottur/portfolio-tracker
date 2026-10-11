import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:asset_portfolio/app/app_controller.dart';
import 'package:asset_portfolio/app/device_prefs.dart';
import 'package:asset_portfolio/main.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:portfolio_core/portfolio_core.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

void main() {
  late Directory tmp;
  late int calls;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    tmp = Directory.systemTemp.createTempSync('ctl');
    calls = 0;
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<AppController> make({DevicePrefs? prefs}) async => AppController(
    prefs: prefs ?? await DevicePrefs.load(),
    privateDir: tmp,
    network: MockClient((_) async {
      calls++;
      fail('network');
    }),
    nowUtc: () => DateTime.utc(2026, 10, 10, 12),
  );

  test('create portfolio writes the descriptor and scans complete', () async {
    final c = await make();
    final f = MemoryRecordFolder();
    await c.openFolder(f, 'mem', createName: 'Main');
    expect(f.descriptor, isNotNull);
    expect(c.scan!.complete, isTrue);
    expect(c.lastValidScan, same(c.scan));
    expect(c.scan!.descriptor!.name, 'Main');
    expect(c.prefs.folderLocation, 'mem');
    expect(c.folderAccessLost, isFalse);
  });

  test('createName on an existing portfolio throws', () async {
    final c = await make();
    final f = MemoryRecordFolder();
    await c.openFolder(f, 'mem', createName: 'Main');
    expect(
      () => c.openFolder(f, 'mem', createName: 'Other'),
      throwsA(isA<StateError>()),
    );
    expect(f.descriptor, isNotNull);
  });

  test('opening an empty folder never creates a descriptor', () async {
    final c = await make();
    final f = MemoryRecordFolder();
    await expectLater(
      c.openFolder(f, 'mem'),
      throwsA(predicate((e) => e.toString().contains('descriptor is missing'))),
    );
    expect(f.descriptor, isNull);
    expect(c.lastValidScan, isNull);
    expect(c.prefs.folderLocation, isNull);
  });

  test('unreadable folder sets folderAccessLost', () async {
    final c = await make();
    await expectLater(c.openFolder(_Broken(), 'x'), throwsA(anything));
    expect(c.folderAccessLost, isTrue);
  });

  test('onResume with no sources enabled makes no network call', () async {
    final c = await make();
    await c.openFolder(MemoryRecordFolder(), 'mem', createName: 'Main');
    await c.onResume();
    expect(calls, 0);
  });

  test('enabling a source persists; disabling notifies', () async {
    final c = await make();
    await c.openFolder(MemoryRecordFolder(), 'mem', createName: 'Main');
    await c.setSourceEnabled('tcmb', true); // no holdings: nothing to fetch
    expect(c.prefs.enabledSources, {'tcmb'});
    var n = 0;
    c.addListener(() => n++);
    await c.setSourceEnabled('tcmb', false);
    expect(c.prefs.enabledSources, isEmpty);
    expect(n, greaterThan(0));
    expect(calls, 0);
  });

  test('setPrivacy persists and notifies', () async {
    final c = await make();
    var n = 0;
    c.addListener(() => n++);
    await c.setPrivacy(true);
    expect(n, 1);
    expect((await DevicePrefs.load()).privacyMode, isTrue);
  });

  test('device id is created once', () async {
    final a = (await DevicePrefs.load()).deviceId;
    expect((await DevicePrefs.load()).deviceId, a);
  });

  test(
    'manual prices persist across controllers with no source enabled',
    () async {
      final f = MemoryRecordFolder();
      final day = DateTime.utc(2026, 10, 9);
      final c1 = await make();
      await c1.openFolder(f, 'mem', createName: 'Main');
      await c1.prices.setManual(
        'XIST:AAA',
        day,
        Decimal.parse('5'),
        nowUtc: DateTime.utc(2026, 10, 10),
      );
      final c2 = await make();
      await c2.openFolder(f, 'mem');
      expect(
        c2.prices.closeOnOrBefore('XIST:AAA', day)?.price,
        Decimal.parse('5'),
      );
      await c2.prices.setManual(
        'XIST:BBB',
        day,
        Decimal.parse('7'),
        nowUtc: DateTime.utc(2026, 10, 10),
      );
      final c3 = await make();
      await c3.openFolder(f, 'mem');
      expect(c3.prices.closeOnOrBefore('XIST:AAA', day), isNotNull);
      expect(c3.prices.closeOnOrBefore('XIST:BBB', day), isNotNull);
    },
  );

  LedgerRecord rec(AppController c) => LedgerRecord.newUpsert(
    portfolioId: c.scan!.descriptor!.portfolioId,
    deviceId: '11111111-1111-4111-8111-111111111111',
    transaction: Transaction.buy(
      instrument: Instrument.create(AssetClass.bistShare, 'AAA'),
      date: DateTime.utc(2026, 10, 1),
      dayOrder: 1,
      quantity: Decimal.one,
      unitPrice: Decimal.one,
      fees: Decimal.zero,
    ),
    now: DateTime.utc(2026, 10, 1),
  );

  test('resume and publish never run folder calls concurrently', () async {
    final c = await make();
    final f = _Flaky();
    await c.openFolder(f, 'mem', createName: 'Main');
    f.slow = true;
    final a = c.onResume();
    final b = c.onResume();
    expect(identical(a, b), isTrue);
    await Future.wait([a, c.publishRecord(rec(c)), c.publishRecord(rec(c))]);
    expect(f.maxActive, 1);
    expect(c.transactions, hasLength(2));
  });

  test(
    'resume on an unreadable folder records access lost, no throw',
    () async {
      final c = await make();
      final f = _Flaky();
      await c.openFolder(f, 'mem', createName: 'Main');
      f.broken = true;
      expect(await c.publishRecord(rec(c)), isFalse); // stays pending
      expect(c.pendingCount, 1);
      await c.onResume();
      expect(c.folderAccessLost, isTrue);
    },
  );

  test(
    'startup restore publishes pending records with no lifecycle event',
    () async {
      final f = _Flaky();
      final c1 = await make();
      await c1.openFolder(f, 'mem', createName: 'Main');
      f.broken = true;
      try {
        await c1.publishRecord(rec(c1));
      } on Object {
        // kept pending either way
      }
      f.broken = false;
      final c2 = await make();
      await c2.restore((_) async => f);
      await c2.rescan(); // queued behind the startup work
      expect(f.records, hasLength(1));
      expect(c2.transactions, hasLength(1));
      expect(c2.pendingCount, 0);
    },
  );

  Future<AppController> withHolding(
    Future<http.Response> Function(http.Request) net,
  ) async {
    final c = AppController(
      prefs: await DevicePrefs.load(),
      privateDir: tmp,
      network: MockClient(net),
      nowUtc: () => DateTime.utc(2026, 10, 10, 12),
    );
    await c.openFolder(MemoryRecordFolder(), 'mem', createName: 'Main');
    await c.publishRecord(rec(c));
    await c.prefs.setEnabledSources({'yahoo'});
    return c;
  }

  test('concurrent price refreshes share one run', () async {
    final gate = Completer<void>();
    final c = await withHolding((_) async {
      calls++;
      await gate.future;
      return http.Response('', 500);
    });
    final a = c.refreshPrices();
    final b = c.refreshPrices(manual: true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    gate.complete();
    await Future.wait([a, b]);
    expect(calls, 2); // the holding and USD/TRY, in one run
  });

  testWidgets('the home screen refreshes prices every 5 minutes', (t) async {
    late AppController c;
    await t.runAsync(() async {
      c = await withHolding((_) async {
        calls++;
        return http.Response('', 500);
      });
    });
    await t.pumpWidget(AssetPortfolioApp(controller: c));
    await t.pump();
    expect(calls, 0);
    await t.pump(const Duration(minutes: 5));
    // The refresh queues behind the price-cache load, which settles in real time.
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await t.pump();
    expect(calls, 2); // the holding and USD/TRY
    await t.pumpWidget(const SizedBox());
  });

  test('create into a folder that has records is refused', () async {
    final c = await make();
    final f = MemoryRecordFolder()..records['x.json'] = Uint8List(1);
    await expectLater(
      c.openFolder(f, 'mem', createName: 'Main'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'This folder already contains records. '
              'Open it as an existing portfolio instead.',
        ),
      ),
    );
    expect(f.descriptor, isNull);
  });

  test('a failed preference write surfaces from the controller', () async {
    final c = await make(
      prefs: _FailPrefs(await SharedPreferences.getInstance()),
    );
    await expectLater(c.setSourceEnabled('tcmb', true), throwsStateError);
    expect(c.prefs.enabledSources, isEmpty);
    expect(calls, 0);
  });

  test('a queued save does not wait for a slow price refresh', () async {
    final gate = Completer<void>();
    final c = AppController(
      prefs: await DevicePrefs.load(),
      privateDir: tmp,
      network: MockClient((_) async {
        await gate.future;
        throw const SocketException('down');
      }),
      nowUtc: () => DateTime.utc(2026, 10, 10, 12),
    );
    await c.openFolder(MemoryRecordFolder(), 'mem', createName: 'Main');
    await c.publishRecord(
      LedgerRecord.newUpsert(
        portfolioId: c.scan!.descriptor!.portfolioId,
        deviceId: '11111111-1111-4111-8111-111111111111',
        transaction: Transaction.buy(
          instrument: Instrument.create(AssetClass.fx, 'USD'),
          date: DateTime.utc(2026, 10, 1),
          dayOrder: 1,
          quantity: Decimal.one,
          unitPrice: Decimal.one,
          fees: Decimal.zero,
        ),
        now: DateTime.utc(2026, 10, 1),
      ),
    );
    await c.prefs.setEnabledSources({'tcmb'});
    final resume = c.onResume();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await c.publishRecord(rec(c)).timeout(const Duration(seconds: 2));
    gate.complete();
    await resume;
  });

  test('a failed preference write rolls the cached value back', () async {
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = _RefusingStore();
    final p = await DevicePrefs.load();
    await expectLater(p.setPrivacyMode(true), throwsStateError);
    expect(p.privacyMode, isFalse);
  });

  group('fetchPriceFor', () {
    final thyao = Instrument.create(AssetClass.bistShare, 'THYAO');
    String fx(String f) =>
        File('packages/portfolio_core/test/fixtures/$f').readAsStringSync();

    test('two concurrent calls run one after another', () async {
      var running = 0, maxRunning = 0;
      final prefs = await DevicePrefs.load();
      await prefs.setEnabledSources({'yahoo'});
      final c = AppController(
        prefs: prefs,
        privateDir: tmp,
        network: MockClient((_) async {
          maxRunning = ++running > maxRunning ? running : maxRunning;
          await Future<void>.delayed(const Duration(milliseconds: 20));
          running--;
          return http.Response(
            fx('yahoo_thyao.json'),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
        nowUtc: () => DateTime.utc(2026, 10, 9, 12),
      );
      final r = await Future.wait([
        c.fetchPriceFor(thyao, c.today),
        c.fetchPriceFor(thyao, c.today),
      ]);
      expect(r.every((o) => o != null), isTrue);
      expect(maxRunning, 1);
    });

    test('today picks the newest of the rows and caches them all', () async {
      final prefs = await DevicePrefs.load();
      await prefs.setEnabledSources({'tefas'});
      final c = AppController(
        prefs: prefs,
        privateDir: tmp,
        network: MockClient((_) async {
          // Oldest first, so "first" is not the newest.
          final j = jsonDecode(fx('tefas_tte_yat.json')) as Map;
          j['resultList'] = (j['resultList'] as List).reversed.toList();
          return http.Response(
            jsonEncode(j),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
        nowUtc: () => DateTime.utc(2026, 10, 10, 12),
      );
      final tte = Instrument.create(AssetClass.fund, 'TTE');
      final o = await c.fetchPriceFor(tte, c.today);
      expect(o!.sessionDate, DateTime.utc(2026, 10, 9));
      expect(
        c.prices
            .closeOnOrBefore(tte.id, DateTime.utc(2026, 10, 5))
            ?.sessionDate,
        DateTime.utc(2026, 10, 5),
      );
    });

    test('a price-cache load waits for a queued fetch', () async {
      final gate = Completer<void>();
      final prefs = await DevicePrefs.load();
      await prefs.setEnabledSources({'yahoo'});
      final c = AppController(
        prefs: prefs,
        privateDir: tmp,
        network: MockClient((_) async {
          await gate.future;
          return http.Response(
            fx('yahoo_thyao.json'),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
        nowUtc: () => DateTime.utc(2026, 10, 9, 12),
      );
      final fetch = c.fetchPriceFor(thyao, c.today);
      var opened = false;
      final open = c
          .openFolder(MemoryRecordFolder(), 'mem', createName: 'Main')
          .then((_) => opened = true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(opened, isFalse);
      gate.complete();
      await fetch;
      await open;
    });

    test('a disabled source throws before any request', () async {
      final c = await make();
      await expectLater(
        c.fetchPriceFor(thyao, c.today),
        throwsA(isA<StateError>()),
      );
      expect(calls, 0);
    });
  });

  group('measures and inflation wiring', () {
    final t0 = DateTime.utc(2026, 10, 1);
    Future<AppController> withTx(
      Set<String> on,
      Future<http.Response> Function(http.Request) h,
    ) async {
      final prefs = await DevicePrefs.load();
      await prefs.setEnabledSources(on);
      final c = AppController(
        prefs: prefs,
        privateDir: tmp,
        network: MockClient(h),
        nowUtc: () => DateTime.utc(2026, 10, 10, 12),
      );
      await c.openFolder(MemoryRecordFolder(), 'mem', createName: 'Main');
      await c.addTransaction(
        Transaction.buy(
          instrument: Instrument.create(AssetClass.bistShare, 'AAA'),
          date: t0,
          dayOrder: 10,
          quantity: Decimal.one,
          unitPrice: Decimal.one,
          fees: Decimal.zero,
        ),
      );
      return c;
    }

    test('get price falls back to binance for a coin btcturk lacks', () async {
      final bnb = Instrument.create(AssetClass.crypto, 'BNB');
      final c = await withTx({'btcturk', 'binance'}, (r) async {
        if (r.url.host == 'api.btcturk.com') {
          return http.Response(
            '{"success":true,"data":[]}',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          '{"symbol":"BNBTRY","price":"700"}',
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final o = await c.fetchPriceFor(bnb, c.today);
      expect(o!.price, Decimal.parse('700'));
      expect(o.source, 'binance');
    });

    test('no fallback when binance is off', () async {
      final hosts = <String>[];
      final c = await withTx({'btcturk'}, (r) async {
        hosts.add(r.url.host);
        return http.Response(
          '{"success":true,"data":[]}',
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      await expectLater(
        c.fetchPriceFor(Instrument.create(AssetClass.crypto, 'BNB'), c.today),
        throwsA(anything),
      );
      expect(hosts.toSet(), {'api.btcturk.com'});
    });

    test('only binance enabled: consent names binance', () async {
      final c = await withTx({'binance'}, (_) async => http.Response('', 500));
      expect(c.priceSourceFor(AssetClass.crypto, c.today).id, 'binance');
    });

    String fx(String f) =>
        File('packages/portfolio_core/test/fixtures/$f').readAsStringSync();

    Future<AppController> twoBuys(
      Set<String> on,
      Future<http.Response> Function(http.Request) h,
    ) async {
      final c = await withTx(on, h);
      await c.addTransaction(
        Transaction.buy(
          instrument: Instrument.create(AssetClass.bistShare, 'AAA'),
          date: DateTime.utc(2026, 10, 5), // Monday
          dayOrder: 10,
          quantity: Decimal.one,
          unitPrice: Decimal.one,
          fees: Decimal.zero,
        ),
      );
      return c;
    }

    test('refresh asks TCMB for each transaction date', () async {
      final paths = <String>[];
      final c = await twoBuys({'tcmb'}, (r) async {
        paths.add(r.url.path);
        // Today's bulletin succeeds so TCMB is not backed off; dated ones 404.
        return r.url.path == '/kurlar/today.xml'
            ? http.Response.bytes(utf8.encode(fx('tcmb_09102026.xml')), 200)
            : http.Response('', 404);
      });
      await c.refreshPrices(manual: true);
      expect(paths, contains('/kurlar/202610/01102026.xml'));
      expect(paths, contains('/kurlar/202610/05102026.xml'));
    });

    test('refresh asks Yahoo for one USD history window', () async {
      final reqs = <Uri>[];
      final c = await twoBuys({'yahoo'}, (r) async {
        reqs.add(r.url);
        return r.url.path.contains('USDTRY')
            ? http.Response(
                fx(
                  r.url.queryParameters.containsKey('period1')
                      ? 'yahoo_usdtry_history.json'
                      : 'yahoo_usdtry.json',
                ),
                200,
                headers: {'content-type': 'application/json'},
              )
            : http.Response('{}', 500);
      });
      await c.refreshPrices(manual: true);
      final h = reqs
          .where(
            (u) =>
                u.path.contains('USDTRY') &&
                u.queryParameters['period1'] != null,
          )
          .toList();
      expect(h.length, 1);
      int secs(DateTime d) => d.millisecondsSinceEpoch ~/ 1000;
      // Window: day before the first buy (09-30), padded 10 days back, and
      // 2026-10-09 (last weekday before "today" 10-10) as the latest baseline;
      // Yahoo itself pads one day each side.
      final from = DateTime.utc(2026, 9, 30).subtract(const Duration(days: 10));
      final to = DateTime.utc(2026, 10, 9);
      expect(
        h.single.queryParameters['period1'],
        '${secs(from.subtract(const Duration(days: 1)))}',
      );
      expect(
        h.single.queryParameters['period2'],
        '${secs(to.add(const Duration(days: 1)))}',
      );
    });

    PriceObservation obs(String id, String day, String price, PriceKind k) =>
        PriceObservation(
          instrumentId: id,
          price: Decimal.parse(price),
          sessionDate: DateTime.parse(day),
          quoteTime: null,
          receivedAt: DateTime.utc(2026, 10, 10),
          source: 'test',
          kind: k,
        );

    test('holdingsIn resolves latest eagerly and never throws later', () async {
      final c = await withTx({'yahoo'}, (_) async => http.Response('', 500));
      expect(c.holdingsIn(Measure.usd), isNull); // no USD/TRY at all
      await c.prices.addFetched([
        obs('FX:USD', '2026-10-01', '40', PriceKind.close),
        obs('XIST:AAA', '2026-10-09', '20', PriceKind.close),
      ]);
      await c.setPrivacy(false); // notifies, so the cached null is dropped
      final (_, lookup) = c.holdingsIn(Measure.usd)!;
      expect(lookup.latest('XIST:AAA')!.price, Decimal.parse('0.5'));
      expect(lookup.closeOnOrBefore('XIST:AAA', c.today), isNull);
    });

    test('get price falls back when btcturk fails outright', () async {
      final c = await withTx({'btcturk', 'binance'}, (r) async {
        if (r.url.host == 'api.btcturk.com') return http.Response('', 500);
        return http.Response(
          '{"symbol":"BNBTRY","price":"700"}',
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final o = await c.fetchPriceFor(
        Instrument.create(AssetClass.crypto, 'BNB'),
        c.today,
      );
      expect(o!.price, Decimal.parse('700'));
    });

    test('inflation refresh runs with only an inflation source', () async {
      final hosts = <String>[];
      final c = await withTx({'tcmbcpi'}, (r) async {
        hosts.add(r.url.host);
        return http.Response('x', 500);
      });
      await c.refreshPrices(manual: true);
      expect(hosts, ['www.tcmb.gov.tr']);
    });

    test('stale USD rate: holdingsIn is null, with the reason', () async {
      final c = await withTx({'yahoo'}, (_) async => http.Response('', 500));
      await c.prices.addFetched([
        obs('FX:USD', '2026-09-01', '40', PriceKind.close),
        obs('XIST:AAA', '2026-10-09', '20', PriceKind.close),
      ]);
      await c.setPrivacy(false);
      expect(c.holdingsIn(Measure.usd), isNull);
      expect(
        c.displayPeriodIn(Measure.usd, Period.lifetime).unavailableReason,
        'Missing USD/TRY rate for 2026-10-01',
      );
    });

    test('holdingsIn and displayPeriodIn are cached until a change', () async {
      final c = await withTx({'yahoo'}, (_) async => http.Response('', 500));
      await c.prices.addFetched([
        obs('FX:USD', '2026-10-01', '40', PriceKind.close),
        obs('XIST:AAA', '2026-10-09', '20', PriceKind.close),
      ]);
      await c.setPrivacy(false);
      final h = c.holdingsIn(Measure.usd);
      final p = c.displayPeriodIn(Measure.usd, Period.lifetime);
      expect(c.holdingsIn(Measure.usd), same(h));
      expect(c.displayPeriodIn(Measure.usd, Period.lifetime), same(p));
      for (final change in [
        () => c.setMeasure(Measure.usd),
        () => c.setPrivacy(true),
        () => c.addTransaction(
          Transaction.buy(
            instrument: Instrument.create(AssetClass.bistShare, 'AAA'),
            date: t0,
            dayOrder: 11,
            quantity: Decimal.one,
            unitPrice: Decimal.one,
            fees: Decimal.zero,
          ),
        ),
      ]) {
        final before = c.holdingsIn(Measure.usd);
        final beforeP = c.displayPeriodIn(Measure.usd, Period.lifetime);
        await change();
        expect(c.holdingsIn(Measure.usd), isNot(same(before)));
        expect(
          c.displayPeriodIn(Measure.usd, Period.lifetime),
          isNot(same(beforeP)),
        );
      }
    });

    test('saving the EVDS key refreshes when evds is enabled', () async {
      final hosts = <String>[];
      Future<http.Response> h(http.Request r) async {
        hosts.add(r.url.host);
        return http.Response('x', 500);
      }

      final off = await withTx({'btcturk'}, h);
      hosts.clear();
      await off.setEvdsKey('k');
      expect(hosts, isEmpty);
      final on = await withTx({'evds'}, h);
      hosts.clear();
      await on.setEvdsKey('k');
      expect(hosts, ['evds3.tcmb.gov.tr']);
      hosts.clear();
      await on.setEvdsKey('  ');
      expect(hosts, isEmpty);
    });

    test('measureUnavailable', () async {
      final c = await withTx({}, (_) async => http.Response('', 500));
      expect(c.measureUnavailable(Measure.tryNominal), isNull);
      expect(
        c.measureUnavailable(Measure.usd),
        'Enable a currency source for USD returns',
      );
      expect(
        c.measureUnavailable(Measure.real),
        'Add inflation data in Settings',
      );
      expect(c.ratesFor(Measure.tryNominal), isNull);
      expect(c.holdingsIn(Measure.usd), isNull);
      expect(c.holdingsIn(Measure.tryNominal), isNotNull);
      await c.setManualCpi('2026-09', Decimal.parse('2'));
      expect(c.measureUnavailable(Measure.real), isNull);
    });

    test(
      'measure preference persists; key is trimmed, empty removes',
      () async {
        final c = await withTx({}, (_) async => http.Response('', 500));
        await c.setMeasure(Measure.usd);
        expect(c.prefs.measure, Measure.usd);
        await c.setEvdsKey('  k ');
        expect(c.prefs.evdsKey, 'k');
        await c.setEvdsKey('  ');
        expect(c.prefs.evdsKey, isNull);
      },
    );
  });
}

class _RefusingStore extends InMemorySharedPreferencesStore {
  _RefusingStore() : super.empty();
  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      false;
}

class _FailPrefs extends DevicePrefs {
  _FailPrefs(super.p);
  @override
  Future<void> setEnabledSources(Set<String> v) async =>
      throw StateError('Could not save settings');
}

class _Flaky extends MemoryRecordFolder {
  bool broken = false, slow = false;
  int active = 0, maxActive = 0;

  Future<T> _t<T>(T Function() f) async {
    if (broken) throw const FileSystemException('gone');
    active++;
    if (active > maxActive) maxActive = active;
    if (slow) await Future<void>.delayed(const Duration(milliseconds: 5));
    active--;
    return f();
  }

  @override
  Future<List<String>> listRecordFiles() => _t(() => records.keys.toList());
  @override
  Future<Uint8List?> readRecordFile(String name) => _t(() => records[name]);
  @override
  Future<Uint8List?> readDescriptor() => _t(() => descriptor);
  @override
  Future<bool> createRecordFile(String name, Uint8List bytes) =>
      _t(() => records.putIfAbsent(name, () => bytes) == bytes);
}

class _Broken extends MemoryRecordFolder {
  @override
  Future<List<String>> listRecordFiles() async =>
      throw const FileSystemException();
}
