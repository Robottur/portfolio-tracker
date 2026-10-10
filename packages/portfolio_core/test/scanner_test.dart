import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:portfolio_core/portfolio_core.dart';
import 'package:test/test.dart';

import 'helpers.dart';

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

class _FlakyFolder extends MemoryRecordFolder {
  String? badName;
  bool failList = false;

  @override
  Future<List<String>> listRecordFiles() =>
      failList ? throw const FileSystemException('x') : super.listRecordFiles();

  @override
  Future<Uint8List?> readRecordFile(String name) => name == badName
      ? throw const FileSystemException('x')
      : super.readRecordFile(name);
}

class _BrokenBlobs extends MemoryBlobStore {
  @override
  Future<Uint8List?> get(String key) => throw const FileSystemException('x');
}

class _FullBlobs extends MemoryBlobStore {
  @override
  Future<void> put(String key, Uint8List bytes) =>
      throw const FileSystemException('x');
}

class _NoKeysBlobs extends MemoryBlobStore {
  @override
  Future<List<String>> keys() => throw const FileSystemException('x');
}

void main() {
  late MemoryRecordFolder folder;
  late MemoryBlobStore retained;
  late LedgerScanner scanner;
  final d = DateTime.utc(2026, 1, 1);

  Future<ScanResult> scan() => scanner.scan(nowUtc: testNow);
  LedgerRecord rec([String price = '1']) => upsert(
    tx: buy(on: d, price: price),
  );

  setUp(() {
    folder = MemoryRecordFolder()..descriptor = descriptorBytes();
    retained = MemoryBlobStore();
    scanner = LedgerScanner(folder, retained);
  });

  test('admits valid records and retains their bytes', () async {
    final r = rec();
    folder.records[r.fileName] = r.encode();
    final s = await scan();
    expect(s.complete, isTrue);
    expect(s.ledger.transactions, hasLength(1));
    expect(await retained.get(r.recordId), r.encode());
  });

  test(
    'missing or invalid descriptor yields one badFile and no scan',
    () async {
      folder.descriptor = null;
      var s = await scan();
      expect(s.descriptor, isNull);
      expect(s.fileIssues.single.kind, IssueKind.badFile);
      expect(
        s.fileIssues.single.message,
        'Portfolio descriptor is missing or invalid',
      );
      folder.descriptor = _b('{');
      s = await scan();
      expect(s.descriptor, isNull);
      expect(s.ledger.leaves, isEmpty);
    },
  );

  test('partial file is badFile; other records still reconcile', () async {
    final good = rec();
    final cut = rec('2');
    folder.records[good.fileName] = good.encode();
    folder.records[cut.fileName] = cut.encode().sublist(0, 40);
    final s = await scan();
    expect(s.complete, isFalse);
    expect(s.fileIssues.single.kind, IssueKind.badFile);
    expect(s.fileIssues.single.recordIds, [cut.fileName]);
    expect(s.ledger.transactions, hasLength(1));
    expect(await retained.get(cut.recordId), isNull);
  });

  test('syncthing temp and hidden files are ignored silently', () async {
    folder.records['.syncthing.x.json.tmp'] = _b('{');
    folder.records['~syncthing~x.json.tmp'] = _b('{');
    folder.records['.stfolder'] = _b('');
    folder.records['.abc.json'] = _b('{');
    folder.records['notes.txt'] = _b('hi');
    final s = await scan();
    expect(s.fileIssues, isEmpty);
    expect(s.complete, isTrue);
  });

  test('unexpected .json names and id/name mismatch are badFile', () async {
    final r = rec();
    folder.records['foo.json'] = r.encode();
    folder.records['$testDeviceId.json'] = r.encode();
    final s = await scan();
    expect(s.fileIssues.map((i) => i.kind), everyElement(IssueKind.badFile));
    expect(s.fileIssues, hasLength(2));
    expect(s.fileIssues.first.message, 'Unexpected file name');
    expect(s.ledger.leaves, isEmpty);
  });

  test(
    'sync-conflict copy: identical ignored, different is conflict',
    () async {
      final r = rec();
      folder.records[r.fileName] = r.encode();
      final cname = '${r.recordId}.sync-conflict-20260101-000000-ABC.json';
      folder.records[cname] = r.encode();
      expect((await scan()).complete, isTrue);

      final other = rec('9');
      folder.records[cname] = _b(
        utf8.decode(other.encode()).replaceAll(other.recordId, r.recordId),
      );
      final s = await scan();
      expect(s.fileIssues.single.kind, IssueKind.contentConflict);
    },
  );

  test('deleted file is missingFile and the transaction stays', () async {
    final r = rec();
    folder.records[r.fileName] = r.encode();
    await scan();
    folder.records.remove(r.fileName);
    final s = await scan();
    final i = s.fileIssues.single;
    expect(i.kind, IssueKind.missingFile);
    expect(i.transactionId, r.transactionId);
    expect(i.recordIds, [r.recordId]);
    expect(i.message, 'A record file disappeared; possible sync damage');
    expect(s.ledger.transactions, hasLength(1));
  });

  test('republishMissing restores the file', () async {
    final r = rec();
    folder.records[r.fileName] = r.encode();
    await scan();
    folder.records.remove(r.fileName);
    final n = await scanner.republishMissing(
      Publisher(folder, MemoryBlobStore()),
    );
    expect(n, 1);
    expect((await scan()).complete, isTrue);
  });

  test('mutated file is contentConflict; original content is kept', () async {
    final r = rec();
    folder.records[r.fileName] = r.encode();
    await scan();
    final changed = rec('7');
    folder.records[r.fileName] = _b(
      utf8.decode(changed.encode()).replaceAll(changed.recordId, r.recordId),
    );
    final s = await scan();
    expect(s.fileIssues.single.kind, IssueKind.contentConflict);
    expect(s.ledger.transactions.single.unitPrice.toString(), '1');
  });

  test('reformatted but same content is not a conflict', () async {
    final r = rec();
    folder.records[r.fileName] = r.encode();
    await scan();
    folder.records[r.fileName] = _b(
      jsonEncode(jsonDecode(utf8.decode(r.encode()))),
    );
    expect((await scan()).complete, isTrue);
  });

  test('unknown schema sets readOnly', () async {
    final r = rec();
    final j = jsonDecode(utf8.decode(r.encode())) as Map<String, dynamic>;
    j['schema_version'] = 99;
    folder.records[r.fileName] = _b(jsonEncode(j));
    final s = await scan();
    expect(s.readOnly, isTrue);
    expect(s.fileIssues.single.kind, IssueKind.unsupportedVersion);
    expect(
      s.fileIssues.single.message,
      'This folder was written by a newer app version',
    );
  });

  test('unreadable file is badFile; others still reconcile', () async {
    final f = _FlakyFolder()..descriptor = descriptorBytes();
    final good = rec();
    final locked = rec('2');
    f.records[good.fileName] = good.encode();
    f.records[locked.fileName] = locked.encode();
    f.badName = locked.fileName;
    final s = await LedgerScanner(f, retained).scan(nowUtc: testNow);
    expect(s.fileIssues.single.kind, IssueKind.badFile);
    expect(s.fileIssues.single.message, 'File could not be read');
    expect(s.fileIssues.single.recordIds, [locked.fileName]);
    expect(s.ledger.transactions, hasLength(1));
  });

  test('unreadable folder gives descriptor null', () async {
    final f = _FlakyFolder()
      ..descriptor = descriptorBytes()
      ..failList = true;
    final s = await LedgerScanner(f, retained).scan(nowUtc: testNow);
    expect(s.descriptor, isNull);
    expect(s.fileIssues.single.message, 'Folder could not be read');
    expect(s.fileIssues.single.recordIds, ['portfolio.json']);
  });

  test('orphan conflict copy is reported', () async {
    final r = rec();
    final cname = '${r.recordId}.sync-conflict-20260101-000000-ABC.json';
    folder.records[cname] = r.encode();
    final s = await scan();
    final i = s.fileIssues.single;
    expect(i.kind, IssueKind.contentConflict);
    expect(i.message, 'Conflict copy without its record file');
    expect(i.recordIds, [cname]);
    expect(i.transactionId, r.transactionId);
    expect(s.ledger.leaves, isEmpty);
  });

  test(
    'unreadable retained copy is reported, folder copy still used',
    () async {
      final r = rec();
      folder.records[r.fileName] = r.encode();
      final blobs = _BrokenBlobs()..data[r.recordId] = r.encode();
      final s = await LedgerScanner(folder, blobs).scan(nowUtc: testNow);
      expect(s.fileIssues.single.kind, IssueKind.badFile);
      expect(
        s.fileIssues.single.message,
        'Private recovery copy could not be read',
      );
      expect(s.fileIssues.single.recordIds, [r.recordId]);
      expect(s.ledger.transactions, hasLength(1));
      expect(blobs.data[r.recordId], r.encode());
    },
  );

  test(
    'unreadable retained copy with missing file is not dropped silently',
    () async {
      final r = rec();
      final blobs = _BrokenBlobs()..data[r.recordId] = r.encode();
      final s = await LedgerScanner(folder, blobs).scan(nowUtc: testNow);
      expect(s.fileIssues.single.kind, IssueKind.badFile);
      expect(
        s.fileIssues.single.message,
        'Private recovery copy could not be read',
      );
      expect(s.fileIssues.single.recordIds, [r.recordId]);
    },
  );

  test('retained put failure is reported; folder copy still used', () async {
    final r = rec();
    folder.records[r.fileName] = r.encode();
    final s = await LedgerScanner(folder, _FullBlobs()).scan(nowUtc: testNow);
    expect(s.fileIssues.single.kind, IssueKind.badFile);
    expect(
      s.fileIssues.single.message,
      'Private recovery copy could not be saved',
    );
    expect(s.fileIssues.single.recordIds, [r.recordId]);
    expect(s.ledger.transactions, hasLength(1));
  });

  test('retained keys failure is reported', () async {
    final r = rec();
    folder.records[r.fileName] = r.encode();
    final s = await LedgerScanner(folder, _NoKeysBlobs()).scan(nowUtc: testNow);
    expect(s.fileIssues.single.message, contains('could not be read'));
    expect(s.ledger.transactions, hasLength(1));
  });
}
