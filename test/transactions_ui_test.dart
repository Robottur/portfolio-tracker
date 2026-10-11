import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:asset_portfolio/app/app_controller.dart';
import 'package:asset_portfolio/app/device_prefs.dart';
import 'package:asset_portfolio/main.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:portfolio_core/portfolio_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _otherDevice = '22222222-2222-4222-8222-222222222222';

Transaction _buy(String sym, String qty, {int order = 10}) => Transaction.buy(
  instrument: Instrument.create(AssetClass.bistShare, sym),
  date: DateTime.utc(2026, 10, 1),
  dayOrder: order,
  quantity: Decimal.parse(qty),
  unitPrice: Decimal.parse('10'),
  fees: Decimal.zero,
);

void main() {
  late Directory tmp;
  late MemoryRecordFolder folder;
  late AppController c;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    tmp = Directory.systemTemp.createTempSync('txui');
    folder = MemoryRecordFolder();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<void> boot(
    WidgetTester tester, {
    Future<void> Function()? seed,
  }) async {
    tester.view.physicalSize = const Size(700, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      c = AppController(
        prefs: await DevicePrefs.load(),
        privateDir: tmp,
        network: MockClient((_) async => fail('network')),
        nowUtc: () => DateTime.utc(2026, 10, 10, 12),
      );
      await c.openFolder(folder, 'mem', createName: 'Main');
      await seed?.call();
    });
    await tester.pumpWidget(AssetPortfolioApp(controller: c));
    await tester.tap(find.byIcon(Icons.receipt_long_outlined));
    await tester.pumpAndSettle();
  }

  // Folder IO runs in the real zone, so give it time between pumps.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 80; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  List<Map<String, Object?>> records() => [
    for (final b in folder.records.values)
      jsonDecode(utf8.decode(b)) as Map<String, Object?>,
  ];

  Future<void> fill(WidgetTester tester, String key, String text) async {
    await tester.enterText(find.byKey(Key(key)), text);
    await tester.pump();
  }

  Finder button(String label) => find.ancestor(
    of: find.text(label),
    matching: find.bySubtype<ButtonStyleButton>(),
  );
  bool enabled(WidgetTester tester, Finder f) =>
      tester.widget<ButtonStyleButton>(f).onPressed != null;

  testWidgets('read-only folder disables editing and says why', (tester) async {
    await boot(
      tester,
      seed: () async {
        await c.addTransaction(_buy('THYAO', '100'));
        folder.records['33333333-3333-4333-8333-333333333333.json'] =
            Uint8List.fromList(utf8.encode('{"schema_version":2}'));
        await c.rescan();
      },
    );
    expect(c.scan!.readOnly, isTrue);
    expect(find.text(AppController.readOnlyMessage), findsOneWidget);
    expect(
      tester
          .widget<FloatingActionButton>(find.byType(FloatingActionButton))
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('BUY THYAO'));
    await tester.pumpAndSettle();
    expect(enabled(tester, button('Correct')), isFalse);
    expect(enabled(tester, button('Void')), isFalse);
    await expectLater(
      c.voidTransaction(c.scan!.ledger.leaves.keys.first),
      throwsStateError,
    );
  });

  testWidgets('BUY THYAO 100 at 10,50 is saved with unit_price 10.5', (
    tester,
  ) async {
    await boot(tester);
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await fill(tester, 'symbol', ' thyao ');
    await fill(tester, 'quantity', '100');
    await fill(tester, 'price', '10,50');
    expect(find.text('= 10.50'), findsOneWidget);
    expect(enabled(tester, button('Save')), isTrue);
    await tester.tap(button('Save'));
    await settle(tester);
    final r = records().single;
    final tx = r['transaction']! as Map<String, Object?>;
    expect(tx['unit_price'], '10.5');
    expect(tx['quantity'], '100');
    expect((tx['instrument']! as Map)['instrument_id'], 'XIST:THYAO');
    expect(find.text('BUY THYAO'), findsOneWidget);
  });

  testWidgets('bad decimal and mixed separators are rejected inline', (
    tester,
  ) async {
    await boot(tester);
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await fill(tester, 'symbol', 'THYAO');
    await fill(tester, 'quantity', '1.234,5');
    expect(find.text('Enter a number like 12.50'), findsOneWidget);
    expect(enabled(tester, button('Save')), isFalse);
  });

  testWidgets('selling more than held shows the issue and blocks Save', (
    tester,
  ) async {
    await boot(tester, seed: () => c.addTransaction(_buy('THYAO', '100')));
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('SELL'));
    await tester.pump();
    await fill(tester, 'symbol', 'THYAO');
    await fill(tester, 'quantity', '200');
    await fill(tester, 'price', '11');
    expect(find.text('Sell quantity exceeds holding'), findsOneWidget);
    expect(enabled(tester, button('Save')), isFalse);
    await fill(tester, 'quantity', '100');
    expect(find.text('Sell quantity exceeds holding'), findsNothing);
    expect(enabled(tester, button('Save')), isTrue);
  });

  testWidgets('gold fixes the symbol and labels grams', (tester) async {
    await boot(tester);
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('assetClass')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Gold').last);
    await tester.pumpAndSettle();
    expect(find.text('grams'), findsOneWidget);
    expect(find.text('GRAM'), findsWidgets);
  });

  testWidgets('BUY Fund tte saves TEFAS:TTE; only BUY and SELL offered', (
    tester,
  ) async {
    await boot(tester);
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('DIVIDEND'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('assetClass')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fund').last);
    await tester.pumpAndSettle();
    for (final t in ['DIVIDEND', 'SPLIT']) {
      expect(
        tester
            .widget<SegmentedButton<TxType>>(
              find.byType(SegmentedButton<TxType>),
            )
            .segments
            .firstWhere((s) => s.label is Text && (s.label! as Text).data == t)
            .enabled,
        isFalse,
      );
    }
    expect(find.text('Fund shares'), findsOneWidget);
    expect(find.text('Fund code, e.g. TTE'), findsOneWidget);
    await fill(tester, 'symbol', ' tte ');
    await fill(tester, 'quantity', '100');
    await fill(tester, 'price', '1,157776');
    await tester.tap(button('Save'));
    await settle(tester);
    final tx = records().single['transaction']! as Map<String, Object?>;
    expect(tx['type'], 'BUY');
    expect(tx['unit_price'], '1.157776');
    expect((tx['instrument']! as Map)['instrument_id'], 'TEFAS:TTE');
  });

  testWidgets('correction supersedes the leaf', (tester) async {
    await boot(tester, seed: () => c.addTransaction(_buy('THYAO', '100')));
    final first = c.scan!.ledger.leaves.values.single.recordId;
    await tester.tap(find.text('BUY THYAO'));
    await tester.pumpAndSettle();
    await tester.tap(button('Correct'));
    await tester.pumpAndSettle();
    await fill(tester, 'quantity', '120');
    await tester.tap(button('Save'));
    await settle(tester);
    final newest = records().firstWhere((r) => r['record_id'] != first);
    expect(newest['supersedes'], [first]);
    expect((newest['transaction']! as Map)['quantity'], '120');
  });

  testWidgets('voiding removes the transaction from the list', (tester) async {
    await boot(tester, seed: () => c.addTransaction(_buy('THYAO', '100')));
    await tester.tap(find.text('BUY THYAO'));
    await tester.pumpAndSettle();
    await tester.tap(button('Void'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Void'));
    await settle(tester);
    expect(find.text('BUY THYAO'), findsNothing);
    expect(records().where((r) => r['operation'] == 'VOID'), hasLength(1));
  });

  testWidgets('competing leaves are resolved by keeping one version', (
    tester,
  ) async {
    late String txId;
    await boot(
      tester,
      seed: () async {
        final pid = c.scan!.descriptor!.portfolioId;
        final a = LedgerRecord.newUpsert(
          portfolioId: pid,
          deviceId: c.prefs.deviceId,
          transaction: _buy('THYAO', '100'),
          now: DateTime.utc(2026, 10, 2),
        );
        txId = a.transactionId;
        final b = LedgerRecord.newUpsert(
          portfolioId: pid,
          deviceId: _otherDevice,
          transaction: _buy('THYAO', '150'),
          transactionId: txId,
          now: DateTime.utc(2026, 10, 3),
        );
        folder.records[a.fileName] = a.encode();
        folder.records[b.fileName] = b.encode();
        await c.rescan();
      },
    );
    final ids = c.scan!.ledger.conflicted[txId]!.map((r) => r.recordId).toSet();
    expect(ids, hasLength(2));
    expect(find.text('1 conflicts need a decision'), findsOneWidget);
    await tester.tap(find.text('1 conflicts need a decision'));
    await tester.pumpAndSettle();
    expect(find.text('Keep this version'), findsNWidgets(2));
    await tester.tap(find.text('Keep this version').first);
    await settle(tester);
    final resolved = records().firstWhere(
      (r) => (r['supersedes']! as List).isNotEmpty,
    );
    expect((resolved['supersedes']! as List).toSet(), ids);
    expect(c.scan!.ledger.conflicted, isEmpty);
    expect(find.text('Keep this version'), findsNothing);
  });

  testWidgets('a correction form opened before a remote edit refuses to save', (
    tester,
  ) async {
    await boot(tester, seed: () => c.addTransaction(_buy('THYAO', '100')));
    final leaf = c.scan!.ledger.leaves.values.single;
    await tester.tap(find.text('BUY THYAO'));
    await tester.pumpAndSettle();
    await tester.tap(button('Correct'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final remote = LedgerRecord.newUpsert(
        portfolioId: c.scan!.descriptor!.portfolioId,
        deviceId: _otherDevice,
        transaction: _buy('THYAO', '150'),
        transactionId: leaf.transactionId,
        supersedes: [leaf.recordId],
        now: DateTime.utc(2026, 10, 3),
      );
      folder.records[remote.fileName] = remote.encode();
      await c.rescan();
    });
    final before = folder.records.length;
    await fill(tester, 'quantity', '120');
    await tester.tap(button('Save'));
    await settle(tester);
    expect(find.text(AppController.changedMessage), findsOneWidget);
    expect(folder.records.length, before);
  });

  testWidgets('a save the folder refuses is kept on this device, not offered '
      'again', (tester) async {
    final f = folder = _Unreachable();
    await boot(tester);
    f.refuse = true;
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await fill(tester, 'symbol', 'THYAO');
    await fill(tester, 'quantity', '100');
    await fill(tester, 'price', '10');
    await tester.tap(button('Save'));
    await settle(tester);
    expect(
      find.text(
        'Saved on this device; it will be written to the folder when it is '
        'reachable.',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('symbol')), findsNothing); // form closed
    expect(f.records, isEmpty);
    final pending = [
      for (final e in Directory('${tmp.path}/pending').listSync())
        if (e is File && !e.uri.pathSegments.last.startsWith('.')) e,
    ];
    expect(pending, hasLength(1));
    final saved = jsonDecode(utf8.decode(pending.single.readAsBytesSync()));
    expect(pending.single.uri.pathSegments.last, saved['record_id']);
    expect(c.pendingCount, 1);
    await tester.tap(find.byIcon(Icons.dashboard_outlined));
    await tester.pumpAndSettle();
    expect(find.text('1 entries waiting to be written'), findsOneWidget);
  });

  testWidgets('privacy mode hides amounts on every screen', (tester) async {
    late String txId;
    await boot(
      tester,
      seed: () async {
        await c.setPrivacy(true);
        final pid = c.scan!.descriptor!.portfolioId;
        final a = LedgerRecord.newUpsert(
          portfolioId: pid,
          deviceId: c.prefs.deviceId,
          transaction: _buy('AKBNK', '777'),
          now: DateTime.utc(2026, 10, 2),
        );
        txId = a.transactionId;
        final b = LedgerRecord.newUpsert(
          portfolioId: pid,
          deviceId: _otherDevice,
          transaction: _buy('AKBNK', '888'),
          transactionId: txId,
          now: DateTime.utc(2026, 10, 3),
        );
        folder.records[a.fileName] = a.encode();
        folder.records[b.fileName] = b.encode();
        await c.rescan();
        await c.addTransaction(_buy('AKBNK', '999', order: 20));
      },
    );
    bool leaks() => find
        .byWidgetPredicate(
          (w) =>
              (w is Text && (w.data ?? '').contains(RegExp('999|888|777'))) ||
              (w is EditableText &&
                  w.controller.text.contains('999') &&
                  !w.obscureText),
        )
        .evaluate()
        .isNotEmpty;
    expect(leaks(), isFalse);
    await tester.tap(find.text('1 conflicts need a decision'));
    await tester.pumpAndSettle();
    expect(find.text('Keep this version'), findsNWidgets(2));
    expect(leaks(), isFalse);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('BUY AKBNK'));
    await tester.pumpAndSettle();
    expect(leaks(), isFalse);
    await tester.tap(button('Correct'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('quantity')), findsOneWidget);
    expect(leaks(), isFalse);
    expect(find.textContaining('= '), findsNothing);
  });
}

class _Unreachable extends MemoryRecordFolder {
  bool refuse = false;

  @override
  Future<bool> createRecordFile(String name, Uint8List bytes) async {
    if (refuse) throw const FileSystemException('unreachable');
    return super.createRecordFile(name, bytes);
  }
}
