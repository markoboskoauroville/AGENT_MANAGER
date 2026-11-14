#!/bin/sh
# build.sh: Agent Manager (Mantra).app, swiftc straight, signed "${SIGN:-Mantra Apps}". GitHub Actions runs it (SIGN=- NO_INSTALL=1);
# on the Mac the release is downloaded, not built (MANTRA_MANIFEST modules/compile-on-github.md).
set -e
cd "$(dirname "$0")"
V=$(sed -n 's/^let VERSION = \([0-9]*\)/\1/p' app/main.swift)
APP="build/Agent Manager (Mantra).app"
rm -rf build; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -o "$APP/Contents/MacOS/AgentManager" app/*.swift -framework AppKit -framework SwiftUI
cp helper/collect.py "$APP/Contents/Resources/collect.py"; cp helper/server.py "$APP/Contents/Resources/server.py"; cp helper/api_money.py "$APP/Contents/Resources/api_money.py"
cp master-prompt.txt "$APP/Contents/Resources/master-prompt.txt"; cp helper/ceo_labels.py "$APP/Contents/Resources/ceo_labels.py"; cp helper/mantra_master.py "$APP/Contents/Resources/mantra_master.py"; cp helper/mantra_block.py "$APP/Contents/Resources/mantra_block.py"; cp helper/mantra_task.py "$APP/Contents/Resources/mantra_task.py"; cp retire-prompt.txt "$APP/Contents/Resources/retire-prompt.txt"
cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Agent Manager (Mantra)</string>
<key>CFBundleDisplayName</key><string>Agent Manager (Mantra)</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIdentifier</key><string>community.auroville.agentmanager</string>
<key>CFBundleExecutable</key><string>AgentManager</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$V</string>
<key>CFBundleVersion</key><string>$V</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PL
codesign --force -s "${SIGN:-Mantra Apps}" "$APP"
[ -n "$NO_INSTALL" ] && { echo "built v$V: $APP"; exit 0; }
echo "built v$V (install the release instead: gh release download)"
