#!/bin/zsh
# Builds CoreGlance.app in ./build.
#   ./build.sh            build only
#   ./build.sh install    build and copy to ~/Applications
#   ./build.sh zip        build and create build/CoreGlance-<version>.zip for a release
set -e
cd "$(dirname "$0")"

VERSION="${VERSION:-1.0.0}"
BUNDLE_ID="${BUNDLE_ID:-io.github.amritadasbijoy.coreglance}"

swift build -c release
APP=build/CoreGlance.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/CoreGlance "$APP/Contents/MacOS/CoreGlance"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>CoreGlance</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>CoreGlance</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough to run locally. For a warning-free download, sign with a
# Developer ID certificate and notarize instead (see README).
codesign --force --sign - "$APP"
echo "Built $APP ($VERSION)"

case "$1" in
install)
    mkdir -p ~/Applications
    rm -rf ~/Applications/CoreGlance.app
    cp -R "$APP" ~/Applications/
    echo "Installed to ~/Applications/CoreGlance.app"
    ;;
zip)
    ditto -c -k --keepParent "$APP" "build/CoreGlance-$VERSION.zip"
    echo "Created build/CoreGlance-$VERSION.zip"
    ;;
esac
