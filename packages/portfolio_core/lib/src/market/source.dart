import 'dart:convert';

import 'package:decimal/decimal.dart';
import 'package:http/http.dart' as http;

import '../model/instrument.dart';
import 'consent_client.dart';
import 'price.dart';

abstract interface class PriceSource {
  String get id;
  String get label;
  List<String> get domains;
  Set<AssetClass> get assetClasses;
  Future<List<PriceObservation>> latest(List<Instrument> instruments);
  Future<List<PriceObservation>> closes(
    Instrument instrument,
    DateTime from,
    DateTime to,
  );
}

class SourceException implements Exception {
  SourceException(this.sourceId, this.message, {this.retryAfter});
  final String sourceId;
  final String message;
  final Duration? retryAfter;

  @override
  String toString() => 'SourceException($sourceId): $message';
}

const requestTimeout = Duration(seconds: 20);

/// Non-2xx (429 keeps its Retry-After) and bodies that are not JSON (block
/// pages served with 200) are errors; callers keep their last good price.
void checkResponse(http.Response r, String sourceId) {
  if (r.statusCode == 429) {
    final secs = int.tryParse(r.headers['retry-after'] ?? '');
    throw SourceException(
      sourceId,
      'Rate limited (429)',
      retryAfter: secs == null ? null : Duration(seconds: secs),
    );
  }
  if (r.statusCode < 200 || r.statusCode > 299) {
    throw SourceException(sourceId, 'HTTP ${r.statusCode}');
  }
}

/// GET [url] and decode JSON; every failure is a [SourceException] except
/// consent denial, which the caller must see as itself.
Future<Object?> getJson(
  http.Client c,
  Uri url,
  String sourceId, {
  Duration timeout = requestTimeout,
}) async {
  final http.Response r;
  try {
    r = await c
        .get(url, headers: {'User-Agent': 'Mozilla/5.0'})
        .timeout(timeout);
  } on ConsentDeniedException {
    rethrow;
  } on Exception catch (e) {
    throw SourceException(sourceId, 'Request failed: ${e.runtimeType}');
  }
  checkResponse(r, sourceId);
  try {
    return jsonDecode(utf8.decode(r.bodyBytes));
  } on FormatException {
    throw SourceException(sourceId, 'Response is not JSON');
  }
}

/// POST [body] as JSON to [url] and decode the JSON reply; same failure
/// contract as [getJson].
Future<Object?> postJson(
  http.Client c,
  Uri url,
  Map<String, Object?> body,
  String sourceId, {
  Map<String, String> headers = const {},
  Duration timeout = requestTimeout,
}) async {
  final http.Response r;
  try {
    r = await c
        .post(
          url,
          headers: {
            'Content-Type': 'application/json',
            'User-Agent': 'Mozilla/5.0',
            ...headers,
          },
          body: jsonEncode(body),
        )
        .timeout(timeout);
  } on ConsentDeniedException {
    rethrow;
  } on Exception catch (e) {
    throw SourceException(sourceId, 'Request failed: ${e.runtimeType}');
  }
  checkResponse(r, sourceId);
  try {
    return jsonDecode(utf8.decode(r.bodyBytes));
  } on FormatException {
    throw SourceException(sourceId, 'Response is not JSON');
  }
}

/// A JSON number as a positive price; never zero, never exponent notation.
Decimal priceFromJson(Object? n, String sourceId) {
  if (n is! num) throw SourceException(sourceId, 'Price is not a number');
  final s = n.toString();
  if (s.contains('e') || s.contains('E') || !n.isFinite || n <= 0) {
    throw SourceException(sourceId, 'Unusable price $s');
  }
  final d = Decimal.parse(s);
  if (!isStorablePrice(d)) throw SourceException(sourceId, 'Unusable price $s');
  return d;
}

/// A decimal string (XML text, BtcTurk strings) as a positive price; plain
/// digits only, so no exponent, sign or locale surprises.
Decimal priceFromString(String s, String sourceId) {
  final t = s.trim();
  final d = RegExp(r'^\d+(\.\d+)?$').hasMatch(t) ? Decimal.tryParse(t) : null;
  if (d == null || !isStorablePrice(d)) {
    throw SourceException(sourceId, 'Unusable price $t');
  }
  return d;
}
