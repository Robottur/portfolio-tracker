import 'dart:io';

import 'package:asset_portfolio/app/app_controller.dart';
import 'package:asset_portfolio/app/device_prefs.dart';
import 'package:asset_portfolio/main.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:portfolio_core/portfolio_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

Decimal _d(String s) => Decimal.parse(s);

void main() {
  late Directory tmp;
  late AppController c;
  final now = DateTime.utc(2026, 3, 1, 12);

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'enabled_sources': ['tcmb'],
    });
    tmp = Directory.systemTemp.createTempSync('measures');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  // BUY 100 @ 10 on 2026-01-05 (USD/TRY 30); now 15 TRY and USD/TRY 40.
  // Inflation 20% from the purchase month to the latest known month.
  Future<void> boot(
    WidgetTester tester, {
    double width = 700,
    bool fx = true,
    Measure? measure,
    String? price = '15',
    bool cpi = true,
  }) async {
    if (!fx) {
      SharedPreferences.setMockInitialValues({
        'enabled_sources': ['btcturk'],
      });
    }
    tester.view.physicalSize = Size(width, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      c = AppController(
        prefs: await DevicePrefs.load(),
        privateDir: tmp,
        network: MockClient((_) async => fail('network')),
        nowUtc: () => now,
      );
      await c.openFolder(MemoryRecordFolder(), 'mem', createName: 'Main');
      await c.addTransaction(
        Transaction.buy(
          instrument: Instrument.create(AssetClass.bistShare, 'AAA'),
          date: DateTime.utc(2026, 1, 5),
          dayOrder: 1,
          quantity: _d('100'),
          unitPrice: _d('10'),
          fees: Decimal.zero,
        ),
      );
      if (price != null) {
        await c.prices.setManual('XIST:AAA', c.today, _d(price), nowUtc: now);
      }
      await c.prices.setManual(
        'FX:USD',
        DateTime.utc(2026, 1, 5),
        _d('30'),
        nowUtc: now,
      );
      await c.prices.setManual('FX:USD', c.today, _d('40'), nowUtc: now);
      if (cpi) await c.prices.setCpi({'2026-02': _d('20')}, 'tcmb');
      if (measure != null) await c.setMeasure(measure);
    });
    await tester.pumpWidget(AssetPortfolioApp(controller: c));
    await tester.pumpAndSettle();
  }

  Future<void> pick(WidgetTester tester, String label) async {
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  Future<void> lifetime(WidgetTester tester) => pick(tester, 'Lifetime');

  testWidgets('usd switch shows dollar values', (tester) async {
    await boot(tester);
    await pick(tester, 'USD');
    expect(find.text('37.50 USD'), findsWidgets);
    expect(find.text('+12.50%'), findsWidgets);
  });

  testWidgets('real switch shows real gain and note', (tester) async {
    await boot(tester);
    await pick(tester, 'Real');
    expect(find.text('+25.00%'), findsWidgets);
    expect(find.text('inflation known through 2026-02'), findsOneWidget);
  });

  testWidgets('comparison line', (tester) async {
    await boot(tester);
    await lifetime(tester);
    expect(find.textContaining('inflation +20.00%'), findsOneWidget);
    expect(find.textContaining('real +25.00%'), findsOneWidget);
    expect(find.textContaining('USD +12.50%'), findsOneWidget);
  });

  testWidgets('usd without fx source shows reason', (tester) async {
    await boot(tester, fx: false);
    await pick(tester, 'USD');
    expect(
      find.text('USD unavailable: Enable a currency source for USD returns'),
      findsOneWidget,
    );
    expect(find.text('1,500.00 TRY'), findsWidgets);
    expect(find.text('37.50 USD'), findsNothing);
  });

  testWidgets('holding marker and detail sentence', (tester) async {
    await boot(tester);
    expect(find.text('real +25.0%'), findsOneWidget);
    await tester.tap(find.text('AAA'));
    await tester.pumpAndSettle();
    expect(find.text('In USD'), findsOneWidget);
    expect(find.text('After inflation'), findsOneWidget);
    expect(
      find.text('Beat inflation by 25.00% since purchase'),
      findsOneWidget,
    );
  });

  testWidgets('privacy hides measure figures', (tester) async {
    await boot(tester, measure: Measure.usd);
    await tester.runAsync(() => c.setPrivacy(true));
    await tester.pumpAndSettle();
    await lifetime(tester);
    Future<void> none() async {
      for (final t in [
        '25.00%',
        'Beat inflation',
        '37.50',
        '33.33',
        '12.50%',
      ]) {
        expect(find.textContaining(t), findsNothing, reason: t);
      }
      expect(find.textContaining('real +'), findsNothing);
      expect(find.textContaining('20.00%'), findsNothing);
    }

    await none();
    await pick(tester, 'Real');
    expect(find.textContaining('1,500.00'), findsNothing);
    await none();
    await pick(tester, 'Pie');
    expect(find.textContaining('100.0%'), findsNothing);
    expect(find.textContaining(' TRY'), findsNothing);
    expect(find.textContaining(' USD'), findsNothing);
    expect(find.textContaining('•'), findsWidgets);
    await pick(tester, 'List');
    await tester.tap(find.text('AAA'));
    await tester.pumpAndSettle();
    expect(find.text('In USD'), findsOneWidget);
    expect(find.text('After inflation'), findsOneWidget);
    await none();
    expect(find.textContaining('1,200.00'), findsNothing);
    expect(find.textContaining('300.00'), findsNothing);
  });

  testWidgets('behind inflation sentence', (tester) async {
    await boot(tester, price: '10');
    await tester.tap(find.text('AAA'));
    await tester.pumpAndSettle();
    expect(find.text('Behind inflation by 16.67%'), findsOneWidget);
  });

  testWidgets('holdings tab follows the measure', (tester) async {
    await boot(tester, measure: Measure.usd);
    await tester.tap(find.text('Holdings'));
    await tester.pumpAndSettle();
    expect(find.text('37.50 USD'), findsOneWidget);
  });

  testWidgets('holdings tab unavailable measure keeps TRY', (tester) async {
    await boot(tester, fx: false, measure: Measure.usd);
    await tester.tap(find.text('Holdings'));
    await tester.pumpAndSettle();
    expect(
      find.text('USD unavailable: Enable a currency source for USD returns'),
      findsOneWidget,
    );
    expect(find.text('1,500.00 TRY'), findsOneWidget);
  });

  testWidgets('comparison line without cpi', (tester) async {
    await boot(tester, cpi: false);
    await lifetime(tester);
    expect(
      find.textContaining('inflation: Add inflation data in Settings'),
      findsOneWidget,
    );
  });

  testWidgets('comparison line with TRY unavailable', (tester) async {
    await boot(tester, price: null);
    await lifetime(tester);
    expect(find.textContaining('TRY: '), findsWidgets);
  });

  testWidgets('sort control: one keyboard stop, one semantics node', (
    tester,
  ) async {
    final sem = tester.ensureSemantics();
    await boot(tester);
    expect(find.bySemanticsLabel(RegExp('Sort: Name')), findsOneWidget);
    var focused = false;
    for (var i = 0; i < 40 && !focused; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final ctx = FocusManager.instance.primaryFocus?.context;
      focused =
          ctx != null &&
          find
              .descendant(
                of: find.byElementPredicate((e) => e == ctx),
                matching: find.textContaining('Sort:'),
              )
              .evaluate()
              .isNotEmpty;
    }
    expect(focused, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('Value'), findsOneWidget);
    sem.dispose();
  });

  testWidgets('sort button is labelled', (tester) async {
    await boot(tester);
    expect(find.text('Sort: Name ▾'), findsOneWidget);
    await tester.tap(find.text('Holdings'));
    await tester.pumpAndSettle();
    expect(find.text('Sort: Name ▾'), findsOneWidget);
  });

  testWidgets('phone width fits', (tester) async {
    await boot(tester, width: 360);
    await lifetime(tester);
    await pick(tester, 'USD');
    await pick(tester, 'Real');
    await tester.tap(find.text('AAA'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
