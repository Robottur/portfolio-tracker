# Asset Portfolio

A private, personal asset tracker for Linux, Windows and Android. You record
buys, sells, share dividends and splits for BIST shares, foreign currencies,
crypto and gold (grams); the app shows holdings, average cost, realized and
unrealized gain in TRY, and a Modified Dietz return estimate per period. It is
a tracker, not a trading tool: there is no cash balance.

## Privacy

- A fresh install makes no network request. Each price source is a separate,
  per-device opt-in.
- When a source is enabled, only the requested symbols (plus ordinary HTTP
  metadata such as IP address and user agent) are sent to that source's domain.
  Quantities, costs and records are never sent.
- No telemetry, analytics, crash reporting, ads or update checks. No accounts.
  The only key is an optional EVDS API key you enter yourself: it is stored
  unencrypted in the app's settings on that device and sent only to
  `evds3.tcmb.gov.tr`.
- Your data is plaintext JSON in a folder you choose and sync yourself with
  Syncthing. There is no app server and no encryption at rest.
- Price sources are unofficial free endpoints (except TCMB); they can break or
  change without notice. Manual price entry always works.
- Privacy mode masks all amounts on screen.

## Build

Toolchain: Flutter 3.47.7 (Dart 3.13.5). Android builds need JDK 17 or 21:
Gradle 9.3.1 cannot run on newer Java ("Unsupported class file major
version"). Point Flutter at one with `flutter config --jdk-dir=<jdk-path>`.

    flutter pub get
    flutter analyze && flutter test
    (cd packages/portfolio_core && dart test)

Builds to publish: Flutter writes the build directory's path into the
binary, so build from a fresh clone at a neutral path. On Linux this script
does that and fails if a shipped file still names your working copy or home
directory (commit first; it builds `HEAD`):

    tool/release_build.sh linux apk     # clones to /tmp/asset_portfolio
    # /tmp/asset_portfolio/build/linux/x64/release/bundle/asset_portfolio
    # /tmp/asset_portfolio/build/app/outputs/flutter-apk/app-release.apk

Linux (on Linux, for local use):

    flutter build linux --release
    # build/linux/x64/release/bundle/asset_portfolio

Windows (on Windows): clone to a neutral path such as `C:\build\asset_portfolio`
first, then:

    flutter build windows --release

Android APK. Create the signing key once, outside the repository, and keep it
for all future upgrades:

    keytool -genkey -v -keystore <path-outside-repo>/portfolio-release.jks -keyalg RSA -keysize 2048 -validity 10000 -alias portfolio -dname "CN=asset_portfolio"
    cp android/key.properties.example android/key.properties   # then fill in the values
    flutter build apk --release
    # build/app/outputs/flutter-apk/app-release.apk

The certificate's name fields are public inside every APK, so keep `-dname`
neutral. `android/key.properties`, `*.jks` and `*.keystore` are git-ignored.
Without `key.properties` a release build stops with an error rather than
signing with debug keys; use `--debug` or `--profile` to test. Verify
permissions (expect only `INTERNET` plus Flutter's
`DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION`):

    $ANDROID_HOME/build-tools/<ver>/aapt2 dump permissions build/app/outputs/flutter-apk/app-release.apk

## Syncthing setup

1. Install Syncthing on each desktop. On Android use Syncthing-Fork (the
   official Syncthing Android app was discontinued in 2024).
2. Create one shared folder and share it between your devices.
3. In the app, choose that folder on each device. On Android the app keeps
   access through the system folder picker; if the permission is revoked, the
   app shows a setup screen with `Choose folder again`.

## Restoring on a new device

Copy the exported backup folder to the new device (or share it there), then
choose `Open existing portfolio` and pick that folder. Do not choose `Create
portfolio` and then `Restore from…`: a new portfolio has a different identity,
so restore refuses with "Destination belongs to a different portfolio" by
design. `Restore from…` is for putting missing records back into the same
portfolio.

## Minimum versions

- Android: minSdk 24 (Android 7.0), the Flutter 3.47.7 default
  (`flutter.minSdkVersion`); all Android plugins used require 24 or lower.
  Target/compile SDK 36.
- Desktop: Flutter 3.47.7 desktop requirements for Linux (GTK 3) and Windows
  (64-bit Windows 10 or later); not verified beyond the checklist in
  `docs/testing/release-checklist.md`.

## Release testing

See `docs/testing/release-checklist.md`. Design: `docs/superpowers/specs/`.

## License

MIT, see `LICENSE`.
