import 'dart:convert';

import 'package:decimal/decimal.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import '../../dates.dart';
import '../../decimal_util.dart';
import '../../model/instrument.dart';
import '../consent_client.dart';
import '../price.dart';
import '../source.dart';

const tcmbHost = 'www.tcmb.gov.tr';
const _maxWalk = 15;

String _two(int n) => n.toString().padLeft(2, '0');

class TcmbSource implements PriceSource {
  TcmbSource(
    this._c, {
    DateTime Function()? nowUtc,
    this.timeout = requestTimeout,
  }) : _now = nowUtc ?? (() => DateTime.now().toUtc());

  final http.Client _c;
  final DateTime Function() _now;
  final Duration timeout;

  @override
  String get id => 'tcmb';
  @override
  String get label => 'TCMB (central bank)';
  @override
  List<String> get domains => const [tcmbHost];
  @override
  Set<AssetClass> get assetClasses => const {AssetClass.fx};

  /// The XML body, or null for 404 (a day with no bulletin).
  Future<String?> _fetch(String path) async {
    final http.Response r;
    try {
      r = await _c
          .get(
            Uri.https(tcmbHost, path),
            headers: {'User-Agent': 'Mozilla/5.0'},
          )
          .timeout(timeout);
    } on ConsentDeniedException {
      rethrow;
    } on Exception catch (e) {
      throw SourceException(id, 'Request failed: ${e.runtimeType}');
    }
    if (r.statusCode == 404) return null;
    checkResponse(r, id);
    return utf8.decode(r.bodyBytes, allowMalformed: true);
  }

  /// Rates by currency code plus the bulletin date.
  (DateTime, Map<String, Decimal>) _parse(String body) {
    final XmlElement root;
    try {
      root = XmlDocument.parse(body).rootElement;
    } on XmlException {
      throw SourceException(id, 'Response is not XML');
    }
    final m = RegExp(r'^(\d{2})/(\d{2})/(\d{4})$')
        .firstMatch(root.getAttribute('Date') ?? '');
    if (root.name.local != 'Tarih_Date' || m == null) {
      throw SourceException(id, 'Unexpected response');
    }
    final DateTime day;
    try {
      day = parseIsoDate('${m[3]}-${m[1]}-${m[2]}');
    } on FormatException {
      throw SourceException(id, 'Bad bulletin date');
    }
    final rates = <String, Decimal>{};
    for (final c in root.findElements('Currency')) {
      final code = c.getAttribute('CurrencyCode');
      final buying = c.getElement('ForexBuying')?.innerText.trim() ?? '';
      final unit = Decimal.tryParse(
        c.getElement('Unit')?.innerText.trim() ?? '',
      );
      if (code == null || buying.isEmpty || rates.containsKey(code)) continue;
      if (unit == null || unit <= Decimal.zero) continue;
      try {
        rates[code] = divide(priceFromString(buying, id), unit);
      } on SourceException {
        continue; // one bad currency must not hide the others
      }
    }
    if (day.isAfter(istanbulToday(_now()))) {
      throw SourceException(id, 'Bulletin dated in the future');
    }
    return (day, rates);
  }

  List<PriceObservation> _observations(
    Iterable<Instrument> wanted,
    DateTime day,
    Map<String, Decimal> rates,
  ) {
    final received = _now();
    return [
      for (final i in wanted)
        if (rates[i.code] case final p? when isStorablePrice(p))
          PriceObservation(
            instrumentId: i.id,
            price: p,
            sessionDate: day,
            quoteTime: null,
            receivedAt: received,
            source: id,
            kind: PriceKind.close,
          ),
    ];
  }

  @override
  Future<List<PriceObservation>> latest(List<Instrument> instruments) async {
    final wanted = instruments.where((i) => i.assetClass == AssetClass.fx);
    if (wanted.isEmpty) return const [];
    final body = await _fetch('/kurlar/today.xml');
    if (body == null) throw SourceException(id, 'HTTP 404');
    final (day, rates) = _parse(body);
    return _observations(wanted, day, rates);
  }

  @override
  Future<List<PriceObservation>> closes(
    Instrument instrument,
    DateTime from,
    DateTime to,
  ) async {
    if (instrument.assetClass != AssetClass.fx) return const [];
    var d = to;
    for (
      var n = 0;
      n < _maxWalk && !d.isBefore(from);
      n++, d = d.subtract(const Duration(days: 1))
    ) {
      final mm = _two(d.month), dd = _two(d.day);
      final body = await _fetch('/kurlar/${d.year}$mm/$dd$mm${d.year}.xml');
      if (body == null) continue;
      final (day, rates) = _parse(body);
      if (day != d) throw SourceException(id, 'Bulletin date mismatch');
      return _observations([instrument], day, rates);
    }
    return const [];
  }
}
