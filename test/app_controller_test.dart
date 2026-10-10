import 'dart:io';
import 'dart:typed_data';

import 'package:asset_portfolio/app/app_controller.dart';
import 'package:asset_portfolio/app/device_prefs.dart';
import 'package:decimal/decimal.dart';
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
      await expectLater(
        c.publishRecord(rec(c)),
        throwsA(anything),
      ); // stays pending
      await c.onResume();
      expect(c.folderAccessLost, isTrue);
    },
  );

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
