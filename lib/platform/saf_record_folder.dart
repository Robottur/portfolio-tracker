import 'dart:typed_data';

import 'package:portfolio_core/portfolio_core.dart';
import 'package:saf_stream/saf_stream.dart';
import 'package:saf_util/saf_util.dart';

const _json = 'application/json';

/// Android folder behind a persisted SAF tree URI. Device-only code: it is not
/// unit-tested here (no device), so it is kept a thin mapping onto the plugins.
class SafRecordFolder implements RecordFolder {
  SafRecordFolder(this.treeUri);

  final String treeUri;
  final _util = SafUtil();
  final _stream = SafStream();

  Future<Uint8List?> _read(String dirUri, String name) async {
    final f = await _util.child(dirUri, [name]);
    return f == null ? null : _stream.readFileBytes(f.uri);
  }

  /// Creates [name] only if absent; a renamed result means SAF found a clash.
  Future<bool> _create(String dirUri, String name, Uint8List bytes) async {
    if (await _util.child(dirUri, [name]) != null) return false;
    final w = await _stream.writeFileBytes(
      dirUri,
      name,
      _json,
      bytes,
      overwrite: false,
    );
    if (w.fileName == name) return true;
    await _util.delete(w.uri.toString(), false);
    return false;
  }

  Future<String> _recordsUri() async =>
      (await _util.mkdirp(treeUri, ['records'])).uri;

  @override
  Future<Uint8List?> readDescriptor() => _read(treeUri, 'portfolio.json');

  @override
  Future<bool> createDescriptor(Uint8List bytes) =>
      _create(treeUri, 'portfolio.json', bytes);

  @override
  Future<List<String>> listRecordFiles() async {
    final dir = await _util.child(treeUri, ['records']);
    if (dir == null) return [];
    return [
      for (final f in await _util.list(dir.uri))
        if (!f.isDir) f.name,
    ]..sort();
  }

  @override
  Future<Uint8List?> readRecordFile(String name) async {
    final dir = await _util.child(treeUri, ['records']);
    return dir == null ? null : _read(dir.uri, name);
  }

  @override
  Future<bool> createRecordFile(String name, Uint8List bytes) async =>
      _create(await _recordsUri(), name, bytes);

  @override
  Future<void> replaceRecordFile(String name, Uint8List bytes) async {
    await _stream.writeFileBytes(
      await _recordsUri(),
      name,
      _json,
      bytes,
      overwrite: true,
    );
  }
}
