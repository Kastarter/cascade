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
</dict>
</plist>
PLIST

# Prefer a stable self-signed identity so macOS TCC grants (Accessibility, Input
# Monitoring, Screen Recording) persist across rebuilds. Falls back to ad-hoc if
# the "Cascade Local Signing" cert isn't installed.
if security find-identity -v 2>/dev/null | grep -q "Cascade Local Signing" \
   || codesign --force --sign "Cascade Local Signing" --identifier "com.humain.cascade" "$APP" 2>/dev/null; then
  codesign --force --deep --sign "Cascade Local Signing" --identifier "com.humain.cascade" "$APP"
else
  codesign --force --deep --sign - --identifier "com.humain.cascade" "$APP"
fi
echo "$APP"
