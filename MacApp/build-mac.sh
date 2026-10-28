#!/bin/bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$DIR/build/Pi Image Manager.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleExecutable</key><string>PiImageManager</string>
<key>CFBundleIdentifier</key><string>org.piimagemanager.mac</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleName</key><string>Pi Image Manager</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.2</string>
<key>CFBundleVersion</key><string>22</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
xcrun swiftc -swift-version 5 -parse-as-library -O -framework AppKit -framework SwiftUI -framework CryptoKit \
  -o "$APP/Contents/MacOS/PiImageManager" "$DIR/PiImageManager.swift"
install -m 0755 "$DIR/stream-backup.sh" "$APP/Contents/Resources/stream-backup.sh"
install -m 0755 "$DIR/build-image-mac.sh" "$APP/Contents/Resources/build-image-mac.sh"
install -m 0755 "$DIR/guest-build-image.sh" "$APP/Contents/Resources/guest-build-image.sh"
codesign --force --deep --sign - "$APP"
echo "Built: $APP"
if [[ "${PIIM_NO_OPEN:-0}" != "1" ]]; then
  open "$APP"
fi
