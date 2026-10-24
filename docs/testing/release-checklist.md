# Release checklist

Fill the Result column on real devices. Android and Windows gates have not been run yet.

## Gates

| # | Gate | Expected | Result |
| --- | --- | --- | --- |
| 1 | `flutter analyze`, `flutter test`, `cd packages/portfolio_core && dart test` | All pass | |
| 2 | `flutter build linux --release`, launch `build/linux/x64/release/bundle/portfolio-tracker` | Builds; app starts and shows setup screen | |
| 3 | On a Windows machine: `flutter build windows --release`, launch the exe | Builds; app starts; folder can be chosen | |
| 4 | Create signing key outside repo, fill `android/key.properties`, `flutter build apk --release`; then `apksigner verify --print-certs build/app/outputs/flutter-apk/app-release.apk` | Signed APK at `build/app/outputs/flutter-apk/app-release.apk`; the printed certificate is your release key, not "Android Debug" | |
| 5 | `$ANDROID_HOME/build-tools/<ver>/aapt2 dump permissions` on the APK | Only `android.permission.INTERNET` plus `DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION`; any storage permission is removed via `tools:node="remove"` | |
| 6 | Android device + Syncthing-Fork: install APK, pick folder, add a record | Record file appears in the folder | |
| 7 | Kill the app, reopen | Folder still accessible, record shown, no re-pick needed | |
| 8 | Send app to background, bring to foreground | State intact, data current | |
| 9 | Revoke the folder permission in system settings, reopen | Setup screen with `Choose folder again`; after re-grant the pending record is still published | |
| 10 | Linux <-> Android: add different records on both while offline, reconnect | Both devices converge to the same union of records | |
| 11 | Windows <-> Android: same offline test | Both devices converge | |
| 12 | Competing correction of the same record on two devices | Conflict view on both; resolved once; both converge | |
| 13 | Privacy: fresh install, no source enabled; desktop `ss -tp` (Android: Settings > Data usage) | Zero outbound connections from the app until a source is enabled | |
| 14 | Enable one source | Connections only to that source's domain; request URLs contain only symbols (no quantities, costs or record data) | |
| 15 | Privacy: Android backup is disabled (`adb shell bmgr backupnow <package>` refuses or backs up nothing for it, or Settings > System > Backup lists no data for the app) | No app data in cloud backup or device transfer (`allowBackup="false"`, `data_extraction_rules.xml` excludes everything) | |

## Recorded versions

| Item | Version |
| --- | --- |
| Flutter | 3.47.7 |
| Dart | 3.13.5 |
| Android device / OS | TBD by tester |
| Android build-tools | TBD by tester |
| Windows / OS | TBD by tester |
| App version | 0.1.0+1 |
