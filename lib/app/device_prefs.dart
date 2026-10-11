import 'package:portfolio_core/portfolio_core.dart' show Measure;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Order of the holding lists; numeric orders are largest first.
enum HoldingSort { name, value, gainTry, gainPercent }

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
  static const _sortKey = 'holding_sort';
  static const _evdsKey = 'evds_key';
  static const _measureKey = 'measure';

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

  HoldingSort get holdingSort =>
      HoldingSort.values.asNameMap()[_p.getString(_sortKey)] ??
      HoldingSort.name;
  Future<void> setHoldingSort(HoldingSort v) =>
      _ok(_p.setString(_sortKey, v.name));

  /// Device-only; never logged, shown or written to the shared folder.
  String? get evdsKey => _p.getString(_evdsKey);
  Future<void> setEvdsKey(String? v) {
    final t = v?.trim() ?? '';
    return _ok(t.isEmpty ? _p.remove(_evdsKey) : _p.setString(_evdsKey, t));
  }

  Measure get measure =>
      Measure.values.asNameMap()[_p.getString(_measureKey)] ??
      Measure.tryNominal;
  Future<void> setMeasure(Measure v) => _ok(_p.setString(_measureKey, v.name));

  // The plugin reports a failed write as false; callers must not carry on.
  Future<void> _ok(Future<bool> write) async {
    if (!await write) {
      await _p.reload(); // drop the cached value the failed write set
      throw StateError('Could not save settings');
    }
  }
}
