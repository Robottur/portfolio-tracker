import 'dart:io';
import 'dart:typed_data';

abstract interface class BlobStore {
  Future<Uint8List?> get(String key);
  Future<void> put(String key, Uint8List bytes);
  Future<void> remove(String key);
  Future<List<String>> keys();
}

class MemoryBlobStore implements BlobStore {
  final Map<String, Uint8List> data = {};

  @override
  Future<Uint8List?> get(String key) async => data[key];

  @override
  Future<void> put(String key, Uint8List bytes) async => data[key] = bytes;

  @override
  Future<void> remove(String key) async => data.remove(key);

  @override
  Future<List<String>> keys() async => data.keys.toList()..sort();
}

/// Keys are file names, so callers must pass plain names (no separators).
class DirBlobStore implements BlobStore {
  DirBlobStore(this.dir);
  final Directory dir;

  File _file(String key) => File('${dir.path}/$key');

  @override
  Future<Uint8List?> get(String key) async {
    final f = _file(key);
    return await f.exists() ? await f.readAsBytes() : null;
  }

  @override
  Future<void> put(String key, Uint8List bytes) async {
    await dir.create(recursive: true);
    final tmp = File('${dir.path}/.$key.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(_file(key).path);
  }

  @override
  Future<void> remove(String key) async {
    final f = _file(key);
    if (await f.exists()) await f.delete();
  }

  @override
  Future<List<String>> keys() async {
    if (!await dir.exists()) return [];
    return [
      await for (final e in dir.list())
        if (e is File && !e.uri.pathSegments.last.startsWith('.'))
          e.uri.pathSegments.last,
    ]..sort();
  }
}
