import 'dart:typed_data';

import '../model/record.dart';
import 'blob_store.dart';
import 'record_folder.dart';

class PublishException implements Exception {
  PublishException(this.code);

  /// collision | verify_failed
  final String code;

  @override
  String toString() => 'PublishException($code)';
}

class Publisher {
  Publisher(this.folder, this.pending);
  final RecordFolder folder;
  final BlobStore pending;

  /// Never overwrites a different complete record; the record stays in
  /// [pending] until the folder is verified to hold it.
  Future<void> publish(LedgerRecord r) async {
    final bytes = r.encode();
    await pending.put(r.recordId, bytes);
    var existing = await folder.readRecordFile(r.fileName);
    if (existing == null && !await folder.createRecordFile(r.fileName, bytes)) {
      existing = await folder.readRecordFile(r.fileName);
    }
    if (existing != null && !_same(existing, r)) {
      // Undecodable means incomplete; repairing is safe only because this
      // device holds the full record pending.
      if (_decodes(existing, r.portfolioId)) {
        throw PublishException('collision');
      }
      await folder.replaceRecordFile(r.fileName, bytes);
    }
    final back = await folder.readRecordFile(r.fileName);
    if (back == null || !_same(back, r)) {
      throw PublishException('verify_failed');
    }
    await pending.remove(r.recordId);
  }

  /// Returns how many pending records were published. Failures leave the
  /// blob in place.
  Future<int> retryPending({required String portfolioId}) async {
    var n = 0;
    for (final key in await pending.keys()) {
      final bytes = await pending.get(key);
      if (bytes == null) continue;
      try {
        await publish(LedgerRecord.decode(bytes, portfolioId: portfolioId));
        n++;
      } on RecordFormatException {
        continue;
      } on PublishException {
        continue;
      }
    }
    return n;
  }

  bool _decodes(Uint8List b, String portfolioId) {
    try {
      LedgerRecord.decode(b, portfolioId: portfolioId);
      return true;
    } on RecordFormatException {
      return false;
    }
  }

  bool _same(Uint8List b, LedgerRecord r) {
    try {
      return LedgerRecord.decode(
        b,
        portfolioId: r.portfolioId,
      ).sameContentAs(r);
    } on RecordFormatException {
      return false;
    }
  }
}
