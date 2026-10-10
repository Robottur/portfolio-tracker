import 'package:http/http.dart' as http;

class ConsentDeniedException implements Exception {
  ConsentDeniedException(this.host);
  final String host;

  @override
  String toString() => 'ConsentDeniedException: $host is not enabled';
}

/// Every adapter gets this, never a raw client: no request leaves unless the
/// user enabled a source that owns the host. The set is read on every request.
class ConsentClient extends http.BaseClient {
  ConsentClient(this._inner, this._allowedHosts);

  final http.Client _inner;
  final Set<String> Function() _allowedHosts;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final host = request.url.host;
    if (!_allowedHosts().contains(host)) throw ConsentDeniedException(host);
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}
