import 'dart:io';

import 'package:asset_portfolio/app/app_controller.dart';
import 'package:asset_portfolio/app/device_prefs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:portfolio_core/portfolio_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory tmp;
  late int calls;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    tmp = Directory.systemTemp.createTempSync('ctl');
    calls = 0;
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<AppController> make() async => AppController(
    prefs: await DevicePrefs.load(),
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
}

class _Broken extends MemoryRecordFolder {
  @override
  Future<List<String>> listRecordFiles() async =>
      throw const FileSystemException();
}
