import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:asset_portfolio/app/app_controller.dart';
import 'package:asset_portfolio/app/device_prefs.dart';
import 'package:asset_portfolio/main.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:portfolio_core/portfolio_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

Transaction _buy(String sym) => Transaction.buy(
  instrument: Instrument.create(AssetClass.bistShare, sym),
  date: DateTime.utc(2026, 10, 1),
  dayOrder: 10,
  quantity: Decimal.parse('5'),
  unitPrice: Decimal.parse('10'),
  fees: Decimal.zero,
);

void main() {
  late Directory tmp;
  late MemoryRecordFolder folder;
  late AppController c;
  final hosts = <String>[];

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    tmp = Directory.systemTemp.createTempSync('setui');
    folder = MemoryRecordFolder();
    hosts.clear();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<http.Response> net(http.Request r) async {
    hosts.add(r.url.host);
    // Canned failure: proves the request went out via the allowed host only.
    return http.Response('{}', 500);
  }

  Future<void> boot(
    WidgetTester tester, {
    Future<void> Function()? seed,
  }) async {
    tester.view.physicalSize = const Size(700, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      c = AppController(
        prefs: await DevicePrefs.load(),
        privateDir: tmp,
        network: MockClient(net),
        nowUtc: () => DateTime.utc(2026, 10, 10, 12),
      );
      await c.openFolder(folder, 'mem', createName: 'Main');
      await seed?.call();
    });
    await tester.pumpWidget(AssetPortfolioApp(controller: c));
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  testWidgets('source switches start off; BtcTurk names its host', (t) async {
    await boot(t);
    final tiles = t.widgetList<SwitchListTile>(find.byType(SwitchListTile));
    final sources = tiles.where(
      (s) =>
          s.title is Text &&
          (s.title as Text).data != 'Hide amounts by default',
    );
    expect(sources.length, 5);
    expect(sources.every((s) => !s.value), isTrue);
    expect(
      find.text(
        'Sends: asset symbols. Contacts: api.btcturk.com. '
        'Your quantities and costs are never sent.',
      ),
      findsOneWidget,
    );
    await t.tap(find.widgetWithText(SwitchListTile, 'BtcTurk'));
    await settle(t);
    expect(c.prefs.enabledSources, {'btcturk'});
    expect(hosts.toSet().difference({'api.btcturk.com'}), isEmpty);
    expect(
      t
          .widget<SwitchListTile>(
            find.widgetWithText(SwitchListTile, 'BtcTurk'),
          )
          .value,
      isTrue,
    );
  });

  testWidgets('a bad file shows its name and message', (t) async {
    await boot(
      t,
      seed: () async {
        folder.records['zzz.json'] = Uint8List.fromList(utf8.encode('nope'));
        await c.rescan();
      },
    );
    expect(find.textContaining('zzz.json'), findsOneWidget);
    expect(find.text('Restore missing records'), findsNothing);
  });

  testWidgets('manual price: inline errors, echo, list, delete', (t) async {
    await boot(t);
    await t.enterText(find.byKey(const Key('manualSymbol')), 'bad symbol!');
    await t.pump();
    expect(find.textContaining('Invalid'), findsWidgets);
    await t.enterText(find.byKey(const Key('manualSymbol')), ' thyao ');
    await t.enterText(find.byKey(const Key('manualPrice')), '12,50');
    await t.pump();
    expect(find.text('= 12.50'), findsOneWidget);
    await t.tap(find.text('Save price'));
    await settle(t);
    expect(c.prices.latest('XIST:THYAO')!.price, Decimal.parse('12.5'));
    expect(find.textContaining('XIST:THYAO'), findsOneWidget);
    expect(find.text('12.50 TRY'), findsOneWidget);
    await t.tap(find.byIcon(Icons.delete_outline));
    await settle(t);
    expect(c.prices.latest('XIST:THYAO'), isNull);
  });

  testWidgets('privacy switch and about text', (t) async {
    await boot(t);
    expect(
      find.text('No telemetry, analytics or crash reporting.'),
      findsOneWidget,
    );
    await t.tap(find.widgetWithText(SwitchListTile, 'Hide amounts by default'));
    await settle(t);
    expect(c.privacyMode, isTrue);
  });

  test('export, restore and republish through the controller', () async {
    SharedPreferences.setMockInitialValues({});
    final other = MemoryRecordFolder();
    final ctl = AppController(
      prefs: await DevicePrefs.load(),
      privateDir: tmp,
      network: MockClient((_) async => fail('network')),
      nowUtc: () => DateTime.utc(2026, 10, 10, 12),
    );
    await expectLater(ctl.exportTo(other), throwsStateError);
    await expectLater(ctl.restoreFrom(other), throwsStateError);
    await expectLater(ctl.republishMissing(), throwsStateError);
    await expectLater(
      ctl.setManualPrice('XIST:A', DateTime.utc(2026, 10, 1), Decimal.one),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'm',
          'The portfolio folder is not available.',
        ),
      ),
    );
    await ctl.openFolder(folder, 'mem', createName: 'Main');
    await ctl.addTransaction(_buy('AAA'));
    final r = await ctl.exportTo(other);
    expect((r.copied, r.alreadyPresent), (1, 0));
    final r2 = await ctl.exportTo(other);
    expect((r2.copied, r2.alreadyPresent), (0, 1));
    // Restore into a fresh portfolio from the exported copy.
    final fresh = MemoryRecordFolder();
    await fresh.createDescriptor(folder.descriptor!);
    final ctl2 = AppController(
      prefs: ctl.prefs,
      privateDir: Directory('${tmp.path}/b')..createSync(),
      network: MockClient((_) async => fail('network')),
      nowUtc: () => DateTime.utc(2026, 10, 10, 12),
    );
    await ctl2.openFolder(fresh, 'mem2');
    final r3 = await ctl2.restoreFrom(other);
    expect(r3.copied, 1);
    expect(ctl2.transactions.length, 1);
  });
}
