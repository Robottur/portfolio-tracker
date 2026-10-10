import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:portfolio_core/portfolio_core.dart';
import 'package:saf_util/saf_util.dart';

import 'saf_record_folder.dart';

typedef PickedFolder = ({RecordFolder folder, String location});

Future<PickedFolder?> pickRecordFolder() async {
  if (Platform.isAndroid) {
    final dir = await SafUtil().pickDirectory(
      writePermission: true,
      persistablePermission: true,
    );
    return dir == null
        ? null
        : (folder: SafRecordFolder(dir.uri), location: dir.uri);
  }
  final path = await FilePicker.getDirectoryPath();
  return path == null
      ? null
      : (folder: IoRecordFolder(Directory(path)), location: path);
}

/// Null when the saved folder is gone or Android revoked the permission.
Future<RecordFolder?> reopenRecordFolder(String location) async {
  if (Platform.isAndroid) {
    final ok = await SafUtil().hasPersistedPermission(
      location,
      checkRead: true,
      checkWrite: true,
    );
    return ok ? SafRecordFolder(location) : null;
  }
  final dir = Directory(location);
  return await dir.exists() ? IoRecordFolder(dir) : null;
}
