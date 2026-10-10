import 'dart:typed_data';

import '../ledger/issue.dart';
import '../ledger/reconcile.dart';
import '../model/record.dart';
import 'blob_store.dart';
import 'publisher.dart';
import 'record_folder.dart';

class ScanResult {
  const ScanResult({
    required this.descriptor,
    required this.ledger,
    required this.fileIssues,
    required this.readOnly,
    required this.scannedAt,
  });

  final PortfolioDescriptor? descriptor;
  final ReconcileResult ledger;
  final List<LedgerIssue> fileIssues;
  final bool readOnly;
  final DateTime scannedAt;

  bool get complete => ledger.issues.isEmpty && fileIssues.isEmpty;
}

final _nameRe = RegExp(
  r'^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})'
  r'(\.sync-conflict-.*)?\.json$',
);

/// Never throws on bad files and never deletes anything.
class LedgerScanner {
  LedgerScanner(this.folder, this.retained);
  final RecordFolder folder;
  final BlobStore retained;

  Future<ScanResult> scan({required DateTime nowUtc}) async {
    ScanResult noPortfolio(String msg) => ScanResult(
      descriptor: null,
      ledger: reconcile(const []),
      fileIssues: [
        LedgerIssue(
          IssueKind.badFile,
          msg,
          recordIds: const ['portfolio.json'],
        ),
      ],
      readOnly: false,
      scannedAt: nowUtc,
    );
    final PortfolioDescriptor? descriptor;
    final List<String> names;
    try {
      descriptor = await _descriptor();
      names = await folder.listRecordFiles();
    } on Exception {
      return noPortfolio('Folder could not be read');
    }
    if (descriptor == null) {
      return noPortfolio('Portfolio descriptor is missing or invalid');
    }
    final pid = descriptor.portfolioId;
    final issues = <LedgerIssue>[];
    var readOnly = false;
    final fed = <String, LedgerRecord>{}; // recordId -> record to reconcile
    final mainBytes = <String, Uint8List>{};
    final conflicts = <String, String>{}; // conflict file name -> record id

    void bad(String name, String msg) =>
        issues.add(LedgerIssue(IssueKind.badFile, msg, recordIds: [name]));

    // Returns null (after recording the issue) if the file is unusable.
    Future<(LedgerRecord, Uint8List)?> read(String name, String id) async {
      final Uint8List? bytes;
      try {
        bytes = await folder.readRecordFile(name);
      } on Exception {
        bad(name, 'File could not be read');
        return null;
      }
      if (bytes == null) return null; // vanished between list and read
      try {
        final r = LedgerRecord.decode(bytes, portfolioId: pid);
        if (r.recordId != id) {
          bad(name, 'Unexpected file name');
          return null;
        }
        return (r, bytes);
      } on RecordFormatException catch (e) {
        if (e.code == 'unsupported_version') {
          readOnly = true;
          issues.add(
            LedgerIssue(
              IssueKind.unsupportedVersion,
              'This folder was written by a newer app version',
              recordIds: [name],
            ),
          );
        } else {
          bad(name, e.message);
        }
        return null;
      }
    }

    for (final name in names) {
      if (!name.endsWith('.json') ||
          name.startsWith('.') ||
          name.startsWith('~')) {
        continue;
      }
      final m = _nameRe.firstMatch(name);
      if (m == null) {
        bad(name, 'Unexpected file name');
        continue;
      }
      if (m.group(2) != null) {
        conflicts[name] = m.group(1)!;
        continue;
      }
      final got = await read(name, m.group(1)!);
      if (got == null) continue;
      fed[got.$1.recordId] = got.$1;
      mainBytes[got.$1.recordId] = got.$2;
    }

    // A throwing retained read is reported once per record, never skipped.
    final unreadable = <String>{};
    Future<Uint8List?> safeGet(String id) async {
      try {
        return await retained.get(id);
      } on Exception {
        if (unreadable.add(id)) {
          issues.add(
            LedgerIssue(
              IssueKind.badFile,
              'Private recovery copy could not be read',
              recordIds: [id],
            ),
          );
        }
        return null;
      }
    }

    for (final e in conflicts.entries) {
      final got = await read(e.key, e.value);
      if (got == null) continue;
      final main = fed[e.value] ?? _decodeOrNull(await safeGet(e.value), pid);
      if (main == null) {
        issues.add(
          LedgerIssue(
            IssueKind.contentConflict,
            'Conflict copy without its record file',
            transactionId: got.$1.transactionId,
            recordIds: [e.key],
          ),
        );
      } else if (!main.sameContentAs(got.$1)) {
        issues.add(
          LedgerIssue(
            IssueKind.contentConflict,
            'Conflicting copies of one record file',
            transactionId: got.$1.transactionId,
            recordIds: [e.value],
          ),
        );
      }
    }

    // Retained copies are the immutable originals; they win over the folder.
    for (final id in mainBytes.keys.toList()) {
      final old = await safeGet(id);
      if (old == null) {
        // Never overwrite a retained copy we could not read.
        if (!unreadable.contains(id)) await retained.put(id, mainBytes[id]!);
        continue;
      }
      final kept = _decodeOrNull(old, pid);
      if (kept == null || !kept.sameContentAs(fed[id]!)) {
        issues.add(
          LedgerIssue(
            IssueKind.contentConflict,
            'A record file was changed after it was written',
            transactionId: fed[id]!.transactionId,
            recordIds: [id],
          ),
        );
        if (kept != null) fed[id] = kept;
      }
    }
    List<String> keys = const [];
    try {
      keys = await retained.keys();
    } on Exception {
      issues.add(
        const LedgerIssue(
          IssueKind.badFile,
          'Private recovery copy could not be read',
        ),
      );
    }
    for (final id in keys) {
      if (fed.containsKey(id)) continue;
      final kept = _decodeOrNull(await safeGet(id), pid);
      if (kept == null || kept.recordId != id) continue;
      fed[id] = kept;
      if (!names.contains(kept.fileName)) {
        issues.add(
          LedgerIssue(
            IssueKind.missingFile,
            'A record file disappeared; possible sync damage',
            transactionId: kept.transactionId,
            recordIds: [id],
          ),
        );
      }
    }

    return ScanResult(
      descriptor: descriptor,
      ledger: reconcile(fed.values),
      fileIssues: issues,
      readOnly: readOnly,
      scannedAt: nowUtc,
    );
  }

  /// Re-publishes retained copies of vanished files; returns how many.
  Future<int> republishMissing(Publisher p) async {
    final res = await scan(nowUtc: DateTime.now().toUtc());
    final pid = res.descriptor?.portfolioId;
    if (pid == null) return 0;
    var n = 0;
    for (final i in res.fileIssues) {
      if (i.kind != IssueKind.missingFile) continue;
      final r = _decodeOrNull(await _get(i.recordIds.single), pid);
      if (r == null) continue;
      try {
        await p.publish(r);
        n++;
      } on PublishException {
        continue;
      }
    }
    return n;
  }

  Future<Uint8List?> _get(String key) async {
    try {
      return await retained.get(key);
    } on Exception {
      return null;
    }
  }

  Future<PortfolioDescriptor?> _descriptor() async {
    final b = await folder.readDescriptor();
    if (b == null) return null;
    try {
      return PortfolioDescriptor.decode(b);
    } on RecordFormatException {
      return null;
    }
  }
}

LedgerRecord? _decodeOrNull(Uint8List? b, String portfolioId) {
  if (b == null) return null;
  try {
    return LedgerRecord.decode(b, portfolioId: portfolioId);
  } on RecordFormatException {
    return null;
  }
}
