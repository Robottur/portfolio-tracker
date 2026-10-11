import 'dart:typed_data';

import 'package:decimal/decimal.dart';
import 'package:portfolio_core/portfolio_core.dart';
import 'package:test/test.dart';

CpiSeries series(Map<String, String> m) => CpiSeries({
  for (final e in m.entries) e.key: CpiEntry(Decimal.parse(e.value), 'evds'),
});

void main() {
  test('chains monthly changes', () {
    final s = series({'2026-01': '10', '2026-02': '10'});
    expect(s.index('2025-12'), Decimal.one);
    expect(s.index('2026-02'), Decimal.parse('1.21'));
    expect(s.change('2025-12', '2026-02'), Decimal.parse('0.21'));
    expect(s.latestMonth, '2026-02');
  });

  test('months after the latest carry its level', () {
    final s = series({'2026-01': '10', '2026-02': '10'});
    expect(s.index('2026-05'), s.index('2026-02'));
  });

  test('index before chain start is null', () {
    final s = series({'2026-01': '10', '2026-02': '10'});
    expect(s.index('2025-11'), isNull);
    expect(s.firstMissing('2025-11', '2026-02'), '2025-11');
    expect(s.change('2025-11', '2026-02'), isNull);
  });

  test('a gap breaks the chain', () {
    final s = series({'2026-01': '10', '2026-03': '10'});
    expect(s.index('2026-03'), isNull);
    expect(s.firstMissing('2026-01', '2026-03'), '2026-02');
  });

  test('gap before from is reported', () {
    final s = series({'2026-01': '10', '2026-03': '10'});
    expect(s.index('2026-03'), isNull);
    expect(s.firstMissing('2026-03', '2026-05'), '2026-02');
  });

  test('percent -100 or less is rejected', () async {
    final blobs = MemoryBlobStore();
    await blobs.put(
      'cpi',
      Uint8List.fromList('{"evds":{"2026-01":"-100","2026-02":"5"}}'.codeUnits),
    );
    final store = PriceStore(blobs);
    await store.load();
    expect(store.cpi.months.keys, ['2026-02']);
    expect(
      () => store.setCpi({'2026-01': Decimal.parse('-100')}, 'tcmb'),
      throwsArgumentError,
    );
    expect(
      () => store.setManualCpi('2026-01', Decimal.parse('-150')),
      throwsArgumentError,
    );
  });

  test('nothing missing inside a full chain', () {
    final s = series({'2026-01': '10', '2026-02': '10'});
    expect(s.firstMissing('2025-12', '2026-09'), isNull);
  });

  test('precedence evds over tcmb over manual', () async {
    final blobs = MemoryBlobStore();
    final store = PriceStore(blobs);
    await store.setManualCpi('2026-01', Decimal.one);
    await store.setCpi({'2026-01': Decimal.fromInt(2)}, 'tcmb');
    await store.setCpi({'2026-01': Decimal.fromInt(3)}, 'evds');
    expect(store.cpi.months['2026-01']!.percent, Decimal.fromInt(3));
    expect(store.cpi.months['2026-01']!.source, 'evds');
    final again = PriceStore(blobs);
    await again.load();
    expect(again.cpi.months['2026-01']!.percent, Decimal.fromInt(3));
    expect(again.cpi.months['2026-01']!.source, 'evds');
    await again.setCpi({}, 'evds');
    await again.setCpi({}, 'tcmb');
    expect(again.cpi.months['2026-01']!.source, 'manual');
    await again.removeManualCpi('2026-01');
    expect(again.cpi.latestMonth, isNull);
  });

  test('malformed cpi blob is ignored', () async {
    final blobs = MemoryBlobStore();
    await blobs.put(
      'cpi',
      Uint8List.fromList('{"evds":{"2026-01":"x"}'.codeUnits),
    );
    final store = PriceStore(blobs);
    await store.load();
    expect(store.cpi.latestMonth, isNull);
  });

  test('manual validation', () {
    final today = DateTime.utc(2026, 10, 11);
    String? v(String m, String p, [Set<String> have = const {}]) =>
        validateManualCpi(m, p, today: today, manualMonths: have);
    expect(v('2026-13', '1'), isNotNull);
    expect(v('2026-11', '1'), isNotNull);
    expect(v('2026-09', '1', {'2026-09'}), isNotNull);
    expect(v('2026-09', '101'), isNotNull);
    expect(v('2026-09', 'abc'), isNotNull);
    expect(v('2026-09', '2,5'), isNull);
    expect(v('2026-10', '-50'), isNull);
  });
}
