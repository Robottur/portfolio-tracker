import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Device-local settings. Never written to the shared folder.
class DevicePrefs {
  DevicePrefs(this._p);

  final SharedPreferences _p;

  static Future<DevicePrefs> load() async {
    final p = DevicePrefs(await SharedPreferences.getInstance());
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
  Future<void> setFolderLocation(String? v) =>
      _ok(v == null ? _p.remove(_folderKey) : _p.setString(_folderKey, v));

  Set<String> get enabledSources =>
      (_p.getStringList(_sourcesKey) ?? const []).toSet();
  Future<void> setEnabledSources(Set<String> v) =>
      _ok(_p.setStringList(_sourcesKey, v.toList()..sort()));

  bool get privacyMode => _p.getBool(_privacyKey) ?? false;
  Future<void> setPrivacyMode(bool v) => _ok(_p.setBool(_privacyKey, v));

  // The plugin reports a failed write as false; callers must not carry on.
  static Future<void> _ok(Future<bool> write) async {
    if (!await write) throw StateError('Could not save settings');
  }
}
