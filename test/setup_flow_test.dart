import 'dart:io';

import 'package:asset_portfolio/app/app_controller.dart';
import 'package:asset_portfolio/app/device_prefs.dart';
import 'package:asset_portfolio/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:portfolio_core/portfolio_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('create portfolio in a real folder, then home shell', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final tmp = Directory.systemTemp.createTempSync('flow');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final shared = Directory('${tmp.path}/shared')..createSync();
    final c = await tester.runAsync(
      () async => AppController(
        prefs: await DevicePrefs.load(),
        privateDir: Directory('${tmp.path}/private'),
        network: MockClient((_) async => fail('network')),
      ),
    );
    await tester.pumpWidget(
      AssetPortfolioApp(
        controller: c!,
        pick: () async =>
            (folder: IoRecordFolder(shared), location: shared.path),
      ),
    );
    expect(find.text('Create portfolio'), findsOneWidget);
    expect(find.text('Open existing portfolio'), findsOneWidget);

    await tester.tap(find.text('Create portfolio'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Main');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle(); // dialog closes, folder IO starts
    // Real file IO: each await continues in the fake zone only after a pump.
    for (var i = 0; i < 50 && find.text('Dashboard').evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();

    expect(File('${shared.path}/portfolio.json').existsSync(), isTrue);
    expect(find.text('Dashboard'), findsWidgets);
    expect(find.byTooltip('Privacy mode'), findsOneWidget);
  });
}
