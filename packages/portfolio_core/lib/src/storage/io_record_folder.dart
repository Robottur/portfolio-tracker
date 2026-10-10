import 'dart:io';
import 'dart:typed_data';

import 'record_folder.dart';

class IoRecordFolder implements RecordFolder {
  IoRecordFolder(this.root);
  final Directory root;

  Directory get _records => Directory('${root.path}/records');
  File get _descriptor => File('${root.path}/portfolio.json');
  File _record(String name) => File('${_records.path}/$name');

  @override
  Future<Uint8List?> readDescriptor() => _read(_descriptor);

  @override
  Future<bool> createDescriptor(Uint8List bytes) async {
    await root.create(recursive: true);
    return _createIfAbsent(
      File('${root.path}/.portfolio.json.tmp'),
      _descriptor,
      bytes,
    );
  }

  @override
  Future<List<String>> listRecordFiles() async {
    if (!await _records.exists()) return [];
    return [
      await for (final e in _records.list())
        if (e is File) e.uri.pathSegments.last,
    ]..sort();
  }

  @override
  Future<Uint8List?> readRecordFile(String name) => _read(_record(name));

  @override
  Future<bool> createRecordFile(String name, Uint8List bytes) async {
    await _records.create(recursive: true);
    return _createIfAbsent(
      File('${_records.path}/.$name.tmp'),
      _record(name),
      bytes,
    );
  }

  @override
  Future<void> replaceRecordFile(String name, Uint8List bytes) async {
    await _records.create(recursive: true);
    final tmp = File('${_records.path}/.$name.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    // shortcut: the directory entry is not fsynced, so a power cut right after publish can lose the rename if pending and shared folder are on different filesystems, upgrade if that setup is needed.
    await tmp.rename(_record(name).path);
  }

  Future<Uint8List?> _read(File f) async =>
      await f.exists() ? await f.readAsBytes() : null;

  Future<bool> _createIfAbsent(File tmp, File target, Uint8List bytes) async {
    await tmp.writeAsBytes(bytes, flush: true);
    // shortcut: exists-check + rename is not atomic against a sync arriving with the same UUID; acceptable because UUID collisions are negligible.
    if (await target.exists()) {
      await tmp.delete();
      return false;
    }
    // shortcut: the directory entry is not fsynced, so a power cut right after publish can lose the rename if pending and shared folder are on different filesystems, upgrade if that setup is needed.
    await tmp.rename(target.path);
    return true;
  }
}
