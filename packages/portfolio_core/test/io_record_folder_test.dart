import 'dart:io';
import 'dart:typed_data';

import 'package:portfolio_core/portfolio_core.dart';
import 'package:test/test.dart';

Uint8List _b(String s) => Uint8List.fromList(s.codeUnits);

void main() {
  late Directory root;
  late IoRecordFolder folder;

  setUp(() {
    root = Directory.systemTemp.createTempSync('rf');
    folder = IoRecordFolder(root);
  });
  tearDown(() => root.deleteSync(recursive: true));

  test(
    'createRecordFile is create-if-absent and leaves no temp files',
    () async {
      expect(await folder.listRecordFiles(), isEmpty);
      expect(await folder.createRecordFile('a.json', _b('one')), isTrue);
      expect(await folder.createRecordFile('a.json', _b('two')), isFalse);
      expect(await folder.readRecordFile('a.json'), _b('one'));
      expect(await folder.listRecordFiles(), ['a.json']);
      final all = Directory('${root.path}/records')
          .listSync()
          .map((e) => e.path);
      expect(all.where((p) => p.endsWith('.tmp')), isEmpty);
    },
  );

  test('replaceRecordFile overwrites', () async {
    await folder.createRecordFile('a.json', _b('one'));
    await folder.replaceRecordFile('a.json', _b('two'));
    expect(await folder.readRecordFile('a.json'), _b('two'));
    expect(await folder.readRecordFile('missing.json'), isNull);
  });

  test(
    'createDescriptor is create-if-absent and leaves no temp files',
    () async {
      expect(await folder.readDescriptor(), isNull);
      expect(await folder.createDescriptor(_b('d1')), isTrue);
      expect(await folder.createDescriptor(_b('d2')), isFalse);
      expect(await folder.readDescriptor(), _b('d1'));
      expect(
        root.listSync().map((e) => e.path).where((p) => p.endsWith('.tmp')),
        isEmpty,
      );
    },
  );

  test('DirBlobStore round-trips', () async {
    final s = DirBlobStore(Directory('${root.path}/blobs'));
    expect(await s.get('k'), isNull);
    await s.put('k', _b('v'));
    expect(await s.get('k'), _b('v'));
    expect(await s.keys(), ['k']);
    await s.remove('k');
    await s.remove('k');
    expect(await s.keys(), isEmpty);
  });
}
