#!/usr/bin/env bash
# Builds release artifacts from a fresh clone at a neutral path, because Flutter
# embeds the build directory in the binary, then fails if a shipped file still
# names the working copy or the home directory.
#
#   tool/release_build.sh [linux] [apk] [appbundle]   (default: linux)
#   BUILD_DIR=/tmp/portfolio-tracker  where to clone and build
#   OFFLINE=1                        resolve packages from the local pub cache
set -euo pipefail

src=$(git -C "$(dirname "$0")/.." rev-parse --show-toplevel)
out=${BUILD_DIR:-/tmp/portfolio-tracker}
targets=("${@:-linux}")

if [ -e "$out" ]; then
  echo "$out already exists; remove it or set BUILD_DIR" >&2
  exit 1
fi
if [[ " ${targets[*]} " =~ \ (apk|appbundle)\  ]]; then
  # Fail before building rather than after Gradle's signing step.
  store=$(sed -n 's/^storeFile=//p' "$src/android/key.properties" 2>/dev/null)
  case $store in /*) ;; ?*) store=$src/android/app/$store ;; esac
  if [ ! -f "$store" ]; then
    echo "android/key.properties must set storeFile to your keystore (see README); got: ${store:-nothing}" >&2
    exit 1
  fi
fi
if [ -n "$(git -C "$src" status --porcelain --untracked-files=no)" ]; then
  echo "Uncommitted changes would not be in the build; commit them first" >&2
  exit 1
fi

git clone --quiet "$src" "$out"
if [ -f "$src/android/key.properties" ]; then
  cp "$src/android/key.properties" "$out/android/key.properties"
fi
cd "$out"
flutter pub get --enforce-lockfile ${OFFLINE:+--offline}
for t in "${targets[@]}"; do
  flutter build "$t" --release --no-pub # packages were fetched above
done

# Only what ships is scanned; intermediate build files name the SDK paths.
shipped=()
for p in build/linux/x64/release/bundle build/app/outputs/flutter-apk/app-release.apk \
  build/app/outputs/bundle/release/app-release.aab; do
  [ -e "$p" ] && shipped+=("$p")
done
leaks=0
for p in "${shipped[@]}"; do
  if [ -d "$p" ]; then
    hits=$(grep -rlaF -e "$src" -e "$HOME" "$p" || true)
  else
    # APK and AAB are zip archives: scan each entry uncompressed.
    # No grep -q: quitting early would fail unzip under pipefail and hide a hit.
    hits=$(unzip -Z1 "$p" | while read -r e; do
      if unzip -p "$p" "$e" | grep -aF -e "$src" -e "$HOME" >/dev/null; then
        echo "$p:$e"
      fi
    done)
  fi
  if [ -n "$hits" ]; then
    echo "Private path found in:" >&2
    echo "$hits" >&2
    leaks=1
  fi
done
[ "$leaks" = 0 ] || exit 1
echo "Clean release build in $out:"
printf '  %s\n' "${shipped[@]}"
