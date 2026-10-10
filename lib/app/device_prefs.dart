import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Device-local settings. Never written to the shared folder.
class DevicePrefs {
  DevicePrefs._(this._p);

  final SharedPreferences _p;

  static Future<DevicePrefs> load() async {
    final p = DevicePrefs._(await SharedPreferences.getInstance());
    if (p._p.getString(_idKey) == null) {
      await p._p.setString(_idKey, const Uuid().v4());
    }
    return p;
  }

  static const _idKey = 'device_id';
  static const _folderKey = 'folder_location';
  static const _sourcesKey = 'enabled_sources';
  static const _privacyKey = 'privacy_mode';

  String get deviceId => _p.getString(_idKey)!;

  String? get folderLocation => _p.getString(_folderKey);
  set folderLocation(String? v) => unawaited(
    v == null ? _p.remove(_folderKey) : _p.setString(_folderKey, v),
  );

  Set<String> get enabledSources =>
      (_p.getStringList(_sourcesKey) ?? const []).toSet();
  set enabledSources(Set<String> v) =>
      unawaited(_p.setStringList(_sourcesKey, v.toList()..sort()));

  bool get privacyMode => _p.getBool(_privacyKey) ?? false;
  set privacyMode(bool v) => unawaited(_p.setBool(_privacyKey, v));
}
