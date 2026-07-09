#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-debug}"
DERIVED="$ROOT/.build/$CONFIGURATION"
APP="$ROOT/.build/Cascade.app"

cd "$ROOT"
swift build -c "$CONFIGURATION"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$DERIVED/Cascade" "$APP/Contents/MacOS/Cascade"
cp "$ROOT/Sources/CascadeApp/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/Sources/CascadeApp/Resources/Images"/cascadeTemplate*.png "$APP/Contents/Resources/"
cp "$ROOT/Sources/CascadeApp/Resources/Images/cascade-white-32.png" "$APP/Contents/Resources/"

# SwiftPM resource bundles (Bundle.module) — e.g. ComputerUseKit's bundled
# app skills. Without these the resource accessor fatalErrors at launch.
for bundle in "$DERIVED"/CascadeNative_*.bundle; do
  [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>Cascade</string>
  <key>CFBundleIdentifier</key>
  <string>com.humain.cascade</string>
  <key>CFBundleName</key>
  <string>Cascade</string>
  <key>CFBundleDisplayName</key>
  <string>Cascade</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright Humain</string>
  <key>NSScreenCaptureUsageDescription</key>
  <string>Cascade records local work context so you can rewind, audit, and approve helper agents.</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Cascade can use the microphone only when you enable voice teaching.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>Cascade transcribes your spoken questions so it can point at what you ask about on screen.</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>With the Power harness enabled, Cascade can drive scriptable apps (Numbers, Mail, Finder) to do bulk work for you — every script is shown and audited.</string>
</dict>
</plist>
PLIST

# Sign with a stable identity so macOS TCC grants (Accessibility, Input
# Monitoring, Screen Recording) persist across rebuilds — ad-hoc signing gives
# every build a fresh cdhash, which resets TCC on each install. Preference:
# Apple Development cert (Apple-trusted, team-stable designated requirement) →
# self-signed "Cascade Local Signing" → ad-hoc (LOUD, so the fallback is never
# silent again).
sign_with() {
  codesign --force --deep --sign "$1" --identifier "com.humain.cascade" "$APP" 2>/dev/null
}
APPLE_DEV_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"')
if [ -n "$APPLE_DEV_IDENTITY" ] && sign_with "$APPLE_DEV_IDENTITY"; then
  echo "signed: $APPLE_DEV_IDENTITY"
elif sign_with "Cascade Local Signing"; then
  echo "signed: Cascade Local Signing"
else
  codesign --force --deep --sign - --identifier "com.humain.cascade" "$APP"
  echo "signed: AD-HOC (TCC grants will reset on install!)" >&2
fi
echo "$APP"
