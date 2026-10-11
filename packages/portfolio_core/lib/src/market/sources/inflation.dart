import 'package:decimal/decimal.dart';
import 'package:http/http.dart' as http;

import '../../decimal_util.dart';
import '../../model/instrument.dart';
import '../price.dart';
import '../source.dart';

/// The EVDS series code; if TÜİK's rebasing changes it, only this changes.
const evdsCpiSeries = 'TP.FG.J0';

const _tcmbPageUrl =
    'https://www.tcmb.gov.tr/wps/wcm/connect/TR/TCMB+TR/Main+Menu/Istatistikler/Enflasyon+Verileri/Tuketici+Fiyatlari';

/// A monthly CPI source. Never routed instruments: [assetClasses] is empty.
abstract interface class InflationSource implements PriceSource {
  /// Monthly CPI change in % keyed `YYYY-MM`.
  Future<Map<String, Decimal>> monthly(DateTime from);
}

mixin _NoPrices {
  Set<AssetClass> get assetClasses => const {};
  Future<List<PriceObservation>> latest(List<Instrument> instruments) async =>
      [];
  Future<List<PriceObservation>> closes(
    Instrument instrument,
    DateTime from,
    DateTime to,
  ) async => [];
}

String _two(int n) => n.toString().padLeft(2, '0');

class TcmbCpiSource with _NoPrices implements InflationSource {
  TcmbCpiSource(this._c, {this.timeout = requestTimeout});
  final http.Client _c;
  final Duration timeout;

  @override
  String get id => 'tcmbcpi';
  @override
  String get label => 'TCMB inflation (CPI)';
  @override
  List<String> get domains => const ['www.tcmb.gov.tr'];

  static const _header = [
    'Ay-Yıl',
    'TÜFE (Yıllık % Değişim)',
    'TÜFE (Aylık % Değişim)',
  ];

  @override
  Future<Map<String, Decimal>> monthly(DateTime from) async {
    final html = await getText(
      _c,
      Uri.parse(_tcmbPageUrl),
      id,
      timeout: timeout,
    );
    final changed = SourceException(
      id,
      'TCMB inflation page changed — enter months manually',
    );
    final rows = <List<String>>[
      for (final tr in RegExp(
        r'<tr[\s>].*?</tr>',
        dotAll: true,
      ).allMatches(html))
        [
          for (final c in RegExp(
            r'<t[dh][\s>].*?</t[dh]>',
            dotAll: true,
          ).allMatches(tr.group(0)!))
            c.group(0)!.replaceAll(RegExp(r'<[^>]*>'), '').trim(),
        ],
    ];
    if (rows.isEmpty || rows.first.join('|') != _header.join('|')) {
      throw changed;
    }
    final out = <String, Decimal>{};
    for (final r in rows.skip(1)) {
      final m = r.length == 3
          ? RegExp(r'^(\d{2})-(\d{4})$').firstMatch(r[0])
          : null;
      final v = m == null || !RegExp(r'^-?\d+(\.\d+)?$').hasMatch(r[2])
          ? null
          : Decimal.tryParse(r[2]);
      if (m == null || v == null) throw changed;
      out['${m[2]}-${m[1]}'] = v;
    }
    if (out.isEmpty) throw changed;
    return out;
  }
}

class EvdsSource with _NoPrices implements InflationSource {
  EvdsSource(
    this._c, {
    required this._key,
    DateTime Function()? nowUtc,
    this.timeout = requestTimeout,
  }) : _now = nowUtc ?? (() => DateTime.now().toUtc());
  final http.Client _c;
  final String? Function() _key;
  final DateTime Function() _now;
  final Duration timeout;

  @override
  String get id => 'evds';
  @override
  String get label => 'TCMB EVDS (inflation)';
  @override
  List<String> get domains => const ['evds3.tcmb.gov.tr'];

  @override
  Future<Map<String, Decimal>> monthly(DateTime from) async {
    final key = _key()?.trim() ?? '';
    if (key.isEmpty) throw SourceException(id, 'Add your EVDS key in Settings');
    final start = DateTime.utc(from.year, from.month - 1);
    final now = _now();
    final url = Uri.parse(
      'https://evds3.tcmb.gov.tr/igmevdsms-dis/series=$evdsCpiSeries'
      '&startDate=01-${_two(start.month)}-${start.year}'
      '&endDate=01-${_two(now.month)}-${now.year}&type=json',
    );
    final Object? body;
    try {
      body = await getJson(
        _c,
        url,
        id,
        headers: {'key': key},
        timeout: timeout,
      );
    } on SourceException catch (e) {
      // checkResponse words these as 'HTTP 401' / 'HTTP 403'.
      if (e.message == 'HTTP 401' || e.message == 'HTTP 403') {
        throw SourceException(id, 'EVDS rejected the key');
      }
      rethrow;
    }
    final items = body is Map ? body['items'] : null;
    if (items is! List) throw SourceException(id, 'Unexpected EVDS reply');
    final levels = <int, Decimal>{}; // year*12 + month-1
    for (final it in items) {
      final t = it is Map ? it['Tarih'] : null;
      final v = it is Map ? it['TP_FG_J0'] : null;
      final m = t is String
          ? RegExp(r'^(\d{4})-(\d{1,2})$').firstMatch(t)
          : null;
      final mo = m == null ? 0 : int.parse(m[2]!);
      if (m == null || mo < 1 || mo > 12) {
        throw SourceException(id, 'Unexpected EVDS month');
      }
      if (v == null || (v is String && v.trim().isEmpty)) continue;
      final d = v is String && RegExp(r'^\d+(\.\d+)?$').hasMatch(v.trim())
          ? Decimal.tryParse(v.trim())
          : null;
      if (d == null || d <= Decimal.zero) {
        throw SourceException(id, 'Unusable EVDS value');
      }
      levels[int.parse(m[1]!) * 12 + mo - 1] = d;
    }
    final out = <String, Decimal>{};
    for (final e in levels.entries) {
      final prev = levels[e.key - 1];
      if (prev == null) continue;
      out['${e.key ~/ 12}-${_two(e.key % 12 + 1)}'] =
          (divide(e.value, prev) - Decimal.one) * Decimal.fromInt(100);
    }
    return out;
  }
}
