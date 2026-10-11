import 'dart:io';

import 'package:asset_portfolio/app/app_controller.dart';
import 'package:asset_portfolio/app/device_prefs.dart';
import 'package:asset_portfolio/main.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:portfolio_core/portfolio_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

Decimal _d(String s) => Decimal.parse(s);

var _order = 0;

Transaction _buy(AssetClass cls, String code, String q, String p) =>
    Transaction.buy(
      instrument: Instrument.create(cls, code),
      date: DateTime.utc(2026, 10, 1),
      dayOrder: ++_order, // one date, so each needs its own order
      quantity: _d(q),
      unitPrice: _d(p),
      fees: Decimal.zero,
    );

void main() {
  late Directory tmp;
  late AppController c;
  final now = DateTime.utc(2026, 10, 10, 12); // a Saturday

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    tmp = Directory.systemTemp.createTempSync('views');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  // Priced total 5,000 TRY: BIST 2,950 (59.0%) + 1 unpriced, Funds 2,050 (41.0%).
  // Value:    TTE 2,050  EEE 1,500  AAA 1,300  BBB 150   CCC —
  // TRY gain: TTE +1,050 AAA +300   BBB +50    EEE −500  CCC —
  // % gain:   TTE +105%  BBB +50%   AAA +30%   EEE −25%  CCC —
  Future<void> boot(WidgetTester tester, {double width = 700}) async {
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
      const bist = AssetClass.bistShare;
      await c.addTransaction(_buy(bist, 'AAA', '100', '10'));
      await c.addTransaction(_buy(bist, 'BBB', '10', '10'));
      await c.addTransaction(_buy(bist, 'CCC', '5', '10'));
      await c.addTransaction(_buy(bist, 'EEE', '10', '200'));
      await c.addTransaction(_buy(AssetClass.fund, 'TTE', '1000', '1'));
      for (final (id, p) in [
        ('XIST:AAA', '13'),
        ('XIST:BBB', '15'),
        ('XIST:EEE', '150'),
        ('TEFAS:TTE', '2.05'),
      ]) {
        await c.prices.setManual(id, c.today, _d(p), nowUtc: now);
      }
    });
    await tester.pumpWidget(AssetPortfolioApp(controller: c));
    await tester.pumpAndSettle();
  }

  Future<void> privacy(WidgetTester tester) async {
    await tester.runAsync(() => c.setPrivacy(true));
    await tester.pumpAndSettle();
  }

  // Codes of the holding rows, top to bottom.
  List<String> rowOrder(WidgetTester tester) {
    final codes = ['AAA', 'BBB', 'CCC', 'EEE', 'TTE'];
    return codes..sort(
      (a, b) => tester
          .getTopLeft(find.text(a))
          .dy
          .compareTo(tester.getTopLeft(find.text(b)).dy),
    );
  }

  Future<void> sortBy(WidgetTester tester, String label) async {
    await tester.tap(find.textContaining('Sort:'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  group('holding rows', () {
    testWidgets('show the gain as TRY and %', (tester) async {
      await boot(tester);
      final aaa = find.ancestor(
        of: find.text('AAA'),
        matching: find.byType(ListTile),
      );
      final eee = find.ancestor(
        of: find.text('EEE'),
        matching: find.byType(ListTile),
      );
      Finder inRow(Finder row, String t) =>
          find.descendant(of: row, matching: find.text(t));
      expect(inRow(aaa, '+300.00 TRY gain'), findsOneWidget);
      expect(inRow(aaa, '+30.00%'), findsOneWidget);
      expect(inRow(eee, '−500.00 TRY loss'), findsOneWidget);
      expect(inRow(eee, '−25.00%'), findsOneWidget);
    });

    testWidgets('privacy mode hides the %', (tester) async {
      await boot(tester);
      await privacy(tester);
      expect(find.textContaining('30.00%'), findsNothing);
    });
  });

  group('class totals', () {
    testWidgets('each class heading shows its priced total', (tester) async {
      await boot(tester);
      expect(find.text('· 2,050.00 TRY'), findsOneWidget);
      expect(find.text('· 2,950.00 TRY'), findsOneWidget);
      expect(find.text('+ 1 unpriced'), findsOneWidget);
    });

    testWidgets('privacy mode hides them', (tester) async {
      await boot(tester);
      await privacy(tester);
      expect(find.textContaining('2,050.00'), findsNothing);
    });
  });

  group('sort', () {
    testWidgets('dashboard sorts within each class', (tester) async {
      await boot(tester);
      await sortBy(tester, 'Value');
      final order = rowOrder(tester);
      expect(order.where((s) => s != 'TTE'), ['EEE', 'AAA', 'BBB', 'CCC']);
    });

    testWidgets('holdings tab: every order, unpriced last', (tester) async {
      await boot(tester);
      await tester.tap(find.text('Holdings'));
      await tester.pumpAndSettle();
      expect(rowOrder(tester), ['AAA', 'BBB', 'CCC', 'EEE', 'TTE']);
      await sortBy(tester, 'Value');
      expect(rowOrder(tester), ['TTE', 'EEE', 'AAA', 'BBB', 'CCC']);
      await sortBy(tester, 'TRY gain');
      expect(rowOrder(tester), ['TTE', 'AAA', 'BBB', 'EEE', 'CCC']);
      await sortBy(tester, '% gain');
      expect(rowOrder(tester), ['TTE', 'BBB', 'AAA', 'EEE', 'CCC']);
      await sortBy(tester, 'Name');
      expect(rowOrder(tester), ['AAA', 'BBB', 'CCC', 'EEE', 'TTE']);
    });

    testWidgets('the choice is saved on the device', (tester) async {
      await boot(tester);
      await sortBy(tester, '% gain');
      final again = await tester.runAsync(DevicePrefs.load);
      expect(again!.holdingSort, HoldingSort.gainPercent);
    });
  });

  group('allocation pie', () {
    Future<void> pie(WidgetTester tester) async {
      await boot(tester);
      await tester.tap(find.text('Pie'));
      await tester.pumpAndSettle();
    }

    testWidgets('legend shows each class share and total', (tester) async {
      await pie(tester);
      expect(find.text('59.0% · 2,950.00 TRY'), findsOneWidget);
      expect(find.text('41.0% · 2,050.00 TRY'), findsOneWidget);
      expect(find.text('Not included (no price): CCC'), findsOneWidget);
    });

    testWidgets('tapping a legend row lists its holdings', (tester) async {
      await pie(tester);
      expect(find.text('AAA'), findsNothing);
      await tester.tap(find.text('BIST share'));
      await tester.pumpAndSettle();
      expect(find.text('AAA'), findsOneWidget);
      expect(find.text('26.0%'), findsOneWidget); // 1,300 / 5,000
      expect(find.text('TTE'), findsNothing);
    });

    testWidgets('tapping a slice lists its holdings', (tester) async {
      await pie(tester);
      final center = tester.getCenter(find.byKey(const Key('allocation-pie')));
      // Slices run clockwise from 12 o'clock: BIST 0–212°, Funds 212–360°.
      await tester.tapAt(center + const Offset(-20, -60)); // about 342°
      await tester.pumpAndSettle();
      expect(find.text('TTE'), findsOneWidget);
      expect(find.text('AAA'), findsNothing);
    });

    testWidgets('privacy mode hides shares and totals', (tester) async {
      await pie(tester);
      await privacy(tester);
      expect(find.textContaining('59.0%'), findsNothing);
      expect(find.text('BIST share'), findsOneWidget);
    });
  });

  testWidgets('phone width: list, pie and holdings fit', (tester) async {
    await boot(tester, width: 360);
    await tester.tap(find.text('Pie'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('BIST share'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Holdings'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  group('market closed', () {
    testWidgets('starts collapsed and expands on tap', (tester) async {
      await boot(tester);
      expect(find.text('Market closed — last prices'), findsOneWidget);
      expect(find.textContaining('XIST:AAA:'), findsNothing);
      await tester.tap(find.text('Market closed — last prices'));
      await tester.pumpAndSettle();
      expect(find.textContaining('XIST:AAA:'), findsOneWidget);
    });
  });
}
