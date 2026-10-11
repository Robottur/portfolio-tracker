import 'package:http/http.dart' as http;

import '../../dates.dart';
import '../../model/instrument.dart';
import '../price.dart';
import '../source.dart';

const tefasHost = 'www.tefas.gov.tr';
const _kinds = ['YAT', 'EMK', 'BYF'];
const _maxSpanDays = 28;

String _ymd(DateTime d) => isoDate(d).replaceAll('-', '');

class TefasSource implements PriceSource {
  TefasSource(
    this._c, {
    DateTime Function()? nowUtc,
    this.knownKind,
    this.rememberKind,
    this.timeout = requestTimeout,
  }) : _now = nowUtc ?? (() => DateTime.now().toUtc());

  final http.Client _c;
  final DateTime Function() _now;
  final String? Function(String code)? knownKind;
  final Future<void> Function(String code, String kind)? rememberKind;
  final Duration timeout;

  @override
  String get id => 'tefas';
  @override
  String get label => 'TEFAS (funds)';
  @override
  List<String> get domains => const [tefasHost];
  @override
  Set<AssetClass> get assetClasses => const {AssetClass.fund};

  static final _emptyMsg = RegExp(
    'out of bounds|veri bulunamad|resultlist',
    caseSensitive: false,
  );

  /// Rows for one window of at most 28 days, plus the fund type that had them
  /// (null when none did). A known type is never re-guessed.
  Future<(List<PriceObservation>, String?)> _window(
    String code,
    String? known,
    DateTime from,
    DateTime to,
  ) async {
    final guessed = known == null;
    for (final kind in guessed ? _kinds : [known]) {
      final json = await postJson(
        _c,
        Uri.https(tefasHost, '/api/funds/fonGnlBlgSiraliGetir'),
        {
          'fonTipi': kind,
          'fonKodu': code,
          'basTarih': _ymd(from),
          'bitTarih': _ymd(to),
          'basSira': 1,
          'bitSira': 100,
          'dil': 'TR',
        },
        id,
        headers: {
          'Origin': 'https://$tefasHost',
          'Referer': 'https://$tefasHost/tr/fon-verileri',
        },
        timeout: timeout,
      );
      if (json is! Map) throw SourceException(id, 'Unexpected response');
      final rows = json['resultList'];
      if (rows is List && rows.isNotEmpty) {
        if (guessed) await rememberKind?.call(code, kind);
        return (_parse(code, rows, from, to), kind);
      }
      final msg = json['errorMessage'];
      if (rows == null && msg is String && !_emptyMsg.hasMatch(msg)) {
        throw SourceException(id, 'TEFAS error'); // never echo server text
      }
    }
    return (const <PriceObservation>[], null);
  }

  List<PriceObservation> _parse(
    String code,
    List rows,
    DateTime from,
    DateTime to,
  ) {
    final received = _now();
    final out = <PriceObservation>[];
    for (final row in rows) {
      if (row is! Map || row['fonKodu'] != code) continue;
      final tarih = row['tarih'];
      if (tarih is! String) throw SourceException(id, 'Bad date');
      final DateTime day;
      try {
        day = parseIsoDate(tarih);
      } on FormatException {
        throw SourceException(id, 'Bad date');
      }
      if (day.isBefore(from) || day.isAfter(to)) continue;
      out.add(
        PriceObservation(
          instrumentId: 'TEFAS:$code',
          price: priceFromJson(row['fiyat'], id),
          sessionDate: day,
          quoteTime: null,
          receivedAt: received,
          source: id,
          kind: PriceKind.close,
        ),
      );
    }
    return out;
  }

  @override
  Future<List<PriceObservation>> latest(List<Instrument> instruments) async {
    final today = istanbulToday(_now());
    final from = today.subtract(const Duration(days: 10));
    final out = <PriceObservation>[];
    SourceException? failure;
    var tried = 0, failed = 0;
    for (final i in instruments.where((i) => i.assetClass == AssetClass.fund)) {
      tried++;
      try {
        final (rows, _) = await _window(
          i.code,
          knownKind?.call(i.code),
          from,
          today,
        );
        if (rows.isNotEmpty) {
          out.add(
            rows.reduce((a, b) => b.sessionDate.isAfter(a.sessionDate) ? b : a),
          );
        }
      } on SourceException catch (e) {
        failure = e;
        failed++;
      }
    }
    if (failure != null && failed == tried) throw failure;
    return out;
  }

  @override
  Future<List<PriceObservation>> closes(
    Instrument instrument,
    DateTime from,
    DateTime to,
  ) async {
    if (instrument.assetClass != AssetClass.fund) return const [];
    final code = instrument.code;
    var kind = knownKind?.call(code);
    final out = <PriceObservation>[];
    for (var end = to; !end.isBefore(from);) {
      var start = end.subtract(const Duration(days: _maxSpanDays));
      if (start.isBefore(from)) start = from;
      final (rows, found) = await _window(code, kind, start, end);
      kind ??= found;
      out.addAll(rows);
      end = start.subtract(const Duration(days: 1));
    }
    return out;
  }
}
