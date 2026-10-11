import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:asset_portfolio/app/app_controller.dart';
import 'package:asset_portfolio/app/device_prefs.dart';
import 'package:asset_portfolio/main.dart';
import 'package:asset_portfolio/platform/folder_access.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:portfolio_core/portfolio_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

Transaction _buy(String sym, {int order = 10}) => Transaction.buy(
  instrument: Instrument.create(AssetClass.bistShare, sym),
  date: DateTime.utc(2026, 10, 1),
  dayOrder: order,
  quantity: Decimal.parse('5'),
  unitPrice: Decimal.parse('10'),
  fees: Decimal.zero,
);

Future<PickedFolder?> _noPick() async => null;

void main() {
  late Directory tmp;
  late MemoryRecordFolder folder;
  late AppController c;
  final hosts = <String>[];
  Future<http.Response> Function(http.Request)? handler;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    tmp = Directory.systemTemp.createTempSync('setui');
    folder = MemoryRecordFolder();
    hosts.clear();
    handler = null;
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<http.Response> net(http.Request r) async {
    hosts.add(r.url.host);
    if (handler != null) return handler!(r);
    // Canned failure: proves the request went out via the allowed host only.
    return http.Response('{}', 500);
  }

  Future<void> boot(
    WidgetTester tester, {
    Future<void> Function()? seed,
    Future<PickedFolder?> Function() pick = _noPick,
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
    await tester.pumpWidget(AssetPortfolioApp(controller: c, pick: pick));
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
    expect(sources.length, 9);
    expect(sources.every((s) => !s.value), isTrue);
    expect(
      find.text(
        'Sends: asset symbols and dates. Contacts: api.btcturk.com. '
        'Your quantities and costs are never sent.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('www.tefas.gov.tr'), findsOneWidget);
    expect(
      find.widgetWithText(SwitchListTile, 'TEFAS (funds)'),
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

  testWidgets(
    'replay issues are listed under Problems; the banner opens them',
    (t) async {
      await boot(
        t,
        seed: () async {
          await c.addTransaction(_buy('AAA'));
          final pid = c.scan!.descriptor!.portfolioId;
          for (final day in [8, 9]) {
            final r = LedgerRecord.newUpsert(
              portfolioId: pid,
              deviceId: c.prefs.deviceId,
              transaction: Transaction.sell(
                instrument: Instrument.create(AssetClass.bistShare, 'AAA'),
                date: DateTime.utc(2026, 10, day),
                dayOrder: 10,
                quantity: Decimal.parse('50'),
                unitPrice: Decimal.parse('10'),
                fees: Decimal.zero,
              ),
              now: DateTime.utc(2026, 10, day),
            );
            folder.records[r.fileName] = r.encode();
          }
          await c.rescan();
        },
      );
      void expectListed() {
        expect(find.text('Sell quantity exceeds holding'), findsNWidgets(2));
        expect(find.text('XIST:AAA, 2026-10-08'), findsOneWidget);
        expect(find.text('XIST:AAA, 2026-10-09'), findsOneWidget);
      }

      expectListed();
      await t.tap(find.byIcon(Icons.dashboard_outlined));
      await t.pumpAndSettle();
      await t.tap(find.text('2 ledger issues'));
      await t.pumpAndSettle();
      expectListed();
    },
  );

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

  testWidgets('unstorable prices are caught inline, never surfaced raw', (
    t,
  ) async {
    await boot(t);
    await t.runAsync(() => c.setPrivacy(true));
    await t.pump();
    await t.enterText(find.byKey(const Key('manualSymbol')), 'thyao');
    for (final bad in ['0', '0,00', '1,123456789', '1234567890123456789']) {
      await t.enterText(find.byKey(const Key('manualPrice')), bad);
      await t.pump();
      expect(
        find.text('Enter a positive price with at most 8 decimals'),
        findsOneWidget,
        reason: bad,
      );
      expect(
        t
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Save price'),
            )
            .onPressed,
        isNull,
      );
    }
    expect(find.textContaining('Invalid argument'), findsNothing);
  });

  testWidgets('manual price makes the dashboard value available', (t) async {
    await boot(t, seed: () async => c.addTransaction(_buy('AAA')));
    await t.tap(find.byIcon(Icons.dashboard_outlined));
    await t.pumpAndSettle();
    expect(find.textContaining('250.00'), findsNothing);
    await t.tap(find.byIcon(Icons.settings_outlined));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('manualSymbol')), 'aaa');
    await t.enterText(find.byKey(const Key('manualPrice')), '50');
    await t.pump();
    await t.tap(find.text('Save price'));
    await settle(t);
    await t.tap(find.byIcon(Icons.dashboard_outlined));
    await t.pumpAndSettle();
    expect(find.textContaining('250.00'), findsWidgets);
  });

  testWidgets('Restore asks first; Cancel copies nothing, Restore copies', (
    t,
  ) async {
    final src = MemoryRecordFolder();
    await boot(
      t,
      pick: () async => (folder: src, location: 'src'),
      seed: () async {
        await src.createDescriptor(folder.descriptor!);
        final other = AppController(
          prefs: c.prefs,
          privateDir: Directory('${tmp.path}/o')..createSync(),
          network: MockClient((_) async => fail('network')),
          nowUtc: () => DateTime.utc(2026, 10, 10, 12),
        );
        await other.openFolder(src, 'src');
        await other.addTransaction(_buy('AAA'));
        await c.prefs.setFolderLocation('mem');
      },
    );
    expect(c.transactions, isEmpty);
    await t.tap(find.text('Restore from…'));
    await t.pumpAndSettle();
    expect(
      find.text('Restore records from this folder into the current portfolio?'),
      findsOneWidget,
    );
    await t.tap(find.text('Cancel'));
    await settle(t);
    expect(folder.records, isEmpty);
    await t.tap(find.text('Restore from…'));
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(TextButton, 'Restore'));
    await settle(t);
    expect(folder.records.length, 1);
    expect(find.text('Copied 1, already present 0'), findsOneWidget);
  });

  test('a refused folder leaves state unchanged', () async {
    final ctl = AppController(
      prefs: await DevicePrefs.load(),
      privateDir: tmp,
      network: MockClient((_) async => fail('network')),
      nowUtc: () => DateTime.utc(2026, 10, 10, 12),
    );
    await ctl.openFolder(folder, 'mem', createName: 'Main');
    await ctl.addTransaction(_buy('AAA'));
    final before = ctl.scan, valid = ctl.lastValidScan;
    await expectLater(
      ctl.openFolder(MemoryRecordFolder(), 'other'),
      throwsStateError,
    );
    expect(ctl.scan, same(before));
    expect(ctl.lastValidScan, same(valid));
    expect(ctl.prefs.folderLocation, 'mem');
    await ctl.addTransaction(
      _buy('BBB', order: 20),
    ); // still writes to the old folder
    expect(folder.records.length, 2);

    // Another portfolio whose first scan is incomplete: no stale "last valid".
    final b2 = MemoryRecordFolder();
    await b2.createDescriptor(PortfolioDescriptor.create('Second').encode());
    b2.records['zzz.json'] = Uint8List.fromList(utf8.encode('nope'));
    await ctl.openFolder(b2, 'bad2');
    expect(ctl.scan!.complete, isFalse);
    expect(ctl.lastValidScan, isNull);
  });

  testWidgets('inflation sources say they send nothing about holdings', (
    t,
  ) async {
    await boot(t);
    expect(
      find.text(
        'Sends: nothing about your holdings. Contacts: www.tcmb.gov.tr.',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('Sends: nothing about your holdings'),
      findsNWidgets(2),
    );
  });

  testWidgets('evds key field is obscured and saved trimmed', (t) async {
    await boot(t);
    final f = find.byKey(const Key('evdsKey'));
    await t.ensureVisible(f);
    await t.enterText(f, '  abc  ');
    await t.testTextInput.receiveAction(TextInputAction.done);
    await t.pump();
    expect(c.prefs.evdsKey, 'abc');
    expect(
      t
          .widget<EditableText>(
            find.descendant(of: f, matching: find.byType(EditableText)),
          )
          .obscureText,
      isTrue,
    );
  });

  testWidgets('evds status shows the rejected key', (t) async {
    handler = (_) async => http.Response('no', 401);
    await boot(t, seed: () => c.prefs.setEvdsKey('k'));
    await t.tap(find.widgetWithText(SwitchListTile, 'TCMB EVDS (inflation)'));
    await settle(t);
    expect(
      find.textContaining('Last error: EVDS rejected the key'),
      findsOneWidget,
    );
    expect(find.textContaining('k\n'), findsNothing);
  });

  testWidgets('add a manual month', (t) async {
    await boot(t);
    await t.ensureVisible(find.byKey(const Key('cpiMonth')));
    await t.enterText(find.byKey(const Key('cpiMonth')), '2026-09');
    await t.enterText(find.byKey(const Key('cpiPercent')), '1,84');
    await t.pump();
    await t.tap(find.text('Add month'));
    await settle(t);
    expect(find.text('2026-09  +1.84%  (manual)'), findsOneWidget);
    expect(c.prices.cpi.months['2026-09']!.source, 'manual');
    await t.tap(find.byTooltip('Delete manual month'));
    await settle(t);
    expect(find.text('2026-09  +1.84%  (manual)'), findsNothing);
  });

  testWidgets('inflation rows stay visible in privacy mode', (t) async {
    await boot(
      t,
      seed: () async {
        await c.setPrivacy(true);
        await c.setManualCpi('2026-09', Decimal.parse('1.84'));
      },
    );
    await t.ensureVisible(find.byKey(const Key('cpiMonth')));
    expect(find.text('2026-09  +1.84%  (manual)'), findsOneWidget);
  });

  testWidgets('invalid month shows the error', (t) async {
    await boot(t);
    await t.ensureVisible(find.byKey(const Key('cpiMonth')));
    await t.enterText(find.byKey(const Key('cpiMonth')), '2027-01');
    await t.enterText(find.byKey(const Key('cpiPercent')), '1,84');
    await t.pump();
    expect(find.text('Month is in the future'), findsOneWidget);
    expect(
      t
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Add month'))
          .onPressed,
      isNull,
    );
  });
}
