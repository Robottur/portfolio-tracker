import 'package:http/http.dart' as http;

import '../../dates.dart';
import '../../model/instrument.dart';
import '../price.dart';
import '../source.dart';

const isYatirimHost = 'www.isyatirim.com.tr';

String _dmy(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}-${d.month.toString().padLeft(2, '0')}-${d.year}';

DateTime _parseDmy(String s, String id) {
  final p = s.split('-');
  if (p.length != 3) throw SourceException(id, 'Bad date $s');
  try {
    return parseIsoDate('${p[2]}-${p[1]}-${p[0]}');
  } on FormatException {
    throw SourceException(id, 'Bad date $s');
  }
}

class IsYatirimSource implements PriceSource {
  IsYatirimSource(
    this._c, {
    DateTime Function()? nowUtc,
    this.timeout = requestTimeout,
  }) : _now = nowUtc ?? (() => DateTime.now().toUtc());

  final http.Client _c;
  final DateTime Function() _now;
  final Duration timeout;

  @override
  String get id => 'isyatirim';
  @override
  String get label => 'İş Yatırım';
  @override
  List<String> get domains => const [isYatirimHost];
  @override
  Set<AssetClass> get assetClasses => const {AssetClass.bistShare};

  @override
  Future<List<PriceObservation>> latest(List<Instrument> instruments) async =>
      const [];

  @override
  Future<List<PriceObservation>> closes(
    Instrument instrument,
    DateTime from,
    DateTime to,
  ) async {
    if (instrument.assetClass != AssetClass.bistShare) return const [];
    final body = await getJson(
      _c,
      Uri.https(
        isYatirimHost,
        '/_layouts/15/Isyatirim.Website/Common/Data.aspx/HisseTekil',
        {
          'hisse': instrument.code,
          'startdate': _dmy(from),
          'enddate': _dmy(to),
        },
      ),
      id,
      timeout: timeout,
    );
    if (body is! Map || body['ok'] != true || body['value'] is! List) {
      throw SourceException(id, 'Unexpected response');
    }
    final received = _now();
    return [
      for (final row in body['value'] as List)
        if (row is Map && row['HGDG_HS_KODU'] != instrument.code)
          ...const <PriceObservation>[] // another symbol's row
        else if (row is Map)
          PriceObservation(
            instrumentId: instrument.id,
            // HG_KAPANIS is unadjusted; HGDG_KAPANIS is split-adjusted.
            price: priceFromJson(row['HG_KAPANIS'], id),
            sessionDate: _parseDmy('${row['HGDG_TARIH']}', id),
            quoteTime: null,
            receivedAt: received,
            source: id,
            kind: PriceKind.close,
          )
        else
          throw SourceException(id, 'Bad row'),
    ];
  }
}
