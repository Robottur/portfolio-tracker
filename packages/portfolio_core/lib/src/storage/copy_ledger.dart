import 'dart:typed_data';

import '../model/record.dart';
import 'record_folder.dart';

class CopyReport {
  CopyReport(this.copied, this.alreadyPresent, this.errors);
  final int copied;
  final int alreadyPresent;
  final List<String> errors;
}

/// Validates everything first; on any error nothing is written.
Future<CopyReport> copyLedger(RecordFolder from, RecordFolder to) async {
  CopyReport fail(String m) => CopyReport(0, 0, [m]);
  final srcBytes = await from.readDescriptor();
  if (srcBytes == null) return fail('Source has no portfolio descriptor');
  final PortfolioDescriptor src;
  try {
    src = PortfolioDescriptor.decode(srcBytes);
  } on RecordFormatException {
    return fail('Source descriptor is invalid');
  }
  final dstBytes = await to.readDescriptor();
  if (dstBytes != null) {
    try {
      if (PortfolioDescriptor.decode(dstBytes).portfolioId != src.portfolioId) {
        return fail('Destination belongs to a different portfolio');
      }
    } on RecordFormatException {
      return fail('Destination descriptor is invalid');
    }
  }

  final files = <String, Uint8List>{};
  final errors = <String>[];
  for (final name in await from.listRecordFiles()) {
    if (!name.endsWith('.json') ||
        name.startsWith('.') ||
        name.startsWith('~')) {
      continue;
    }
    final bytes = await from.readRecordFile(name);
    try {
      if (bytes == null) throw RecordFormatException('bad_json', 'unreadable');
      final r = LedgerRecord.decode(bytes, portfolioId: src.portfolioId);
      if (r.fileName != name) {
        errors.add('Unexpected file name: $name');
        continue;
      }
      files[name] = bytes;
    } on RecordFormatException catch (e) {
      errors.add('$name: ${e.message}');
    }
  }
  if (errors.isNotEmpty) return CopyReport(0, 0, errors);

  await to.createDescriptor(srcBytes);
  var copied = 0, present = 0;
  for (final e in files.entries) {
    if (await to.createRecordFile(e.key, e.value)) {
      copied++;
      continue;
    }
    final have = await to.readRecordFile(e.key);
    if (have != null && _same(have, e.value, src.portfolioId)) {
      present++;
    } else {
      errors.add('${e.key}: destination holds different content');
    }
  }
  return CopyReport(copied, present, errors);
}

bool _same(Uint8List a, Uint8List b, String portfolioId) {
  try {
    return LedgerRecord.decode(
      a,
      portfolioId: portfolioId,
    ).sameContentAs(LedgerRecord.decode(b, portfolioId: portfolioId));
  } on RecordFormatException {
    return false;
  }
}
