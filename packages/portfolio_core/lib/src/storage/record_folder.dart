import 'dart:typed_data';

/// `create*` returns false and writes nothing if the target already exists.
abstract interface class RecordFolder {
  Future<Uint8List?> readDescriptor();
  Future<bool> createDescriptor(Uint8List bytes);

  /// Bare file names inside `records/`, sorted.
  Future<List<String>> listRecordFiles();
  Future<Uint8List?> readRecordFile(String name);
  Future<bool> createRecordFile(String name, Uint8List bytes);
  Future<void> replaceRecordFile(String name, Uint8List bytes);
}

/// Test double; tests may write [records] and [descriptor] directly to
/// simulate a truncated file or a sync arrival.
class MemoryRecordFolder implements RecordFolder {
  final Map<String, Uint8List> records = {};
  Uint8List? descriptor;

  @override
  Future<Uint8List?> readDescriptor() async => descriptor;

  @override
  Future<bool> createDescriptor(Uint8List bytes) async {
    if (descriptor != null) return false;
    descriptor = bytes;
    return true;
  }

  @override
  Future<List<String>> listRecordFiles() async => records.keys.toList()..sort();

  @override
  Future<Uint8List?> readRecordFile(String name) async => records[name];

  @override
  Future<bool> createRecordFile(String name, Uint8List bytes) async {
    if (records.containsKey(name)) return false;
    records[name] = bytes;
    return true;
  }

  @override
  Future<void> replaceRecordFile(String name, Uint8List bytes) async =>
      records[name] = bytes;
}
