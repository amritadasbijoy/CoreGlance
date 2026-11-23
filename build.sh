#!/bin/zsh
# Builds CoreGlance.app in ./build.
#   ./build.sh            build only
#   ./build.sh install    build and copy to ~/Applications
#   ./build.sh zip        build and create build/CoreGlance-<version>.zip
#   ./build.sh dmg        build and create build/CoreGlance-<version>.dmg
#   ./build.sh release    build and create both (the zip is what Homebrew installs)
set -e
cd "$(dirname "$0")"

VERSION="${VERSION:-1.0.4}"
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

make_zip() {
    ditto -c -k --keepParent "$APP" "build/CoreGlance-$VERSION.zip"
    echo "Created build/CoreGlance-$VERSION.zip"
}

# A disk image with the app next to a shortcut to Applications, so people drag it across.
make_dmg() {
    local stage=build/dmg
    rm -rf "$stage" "build/CoreGlance-$VERSION.dmg"
    mkdir -p "$stage"
    cp -R "$APP" "$stage/"
    ln -s /Applications "$stage/Applications"
    hdiutil create -quiet -volname CoreGlance -srcfolder "$stage" -format UDZO "build/CoreGlance-$VERSION.dmg"
    rm -rf "$stage"
    echo "Created build/CoreGlance-$VERSION.dmg"
}

case "$1" in
install)
    mkdir -p ~/Applications
    rm -rf ~/Applications/CoreGlance.app
    cp -R "$APP" ~/Applications/
    rm -rf "$APP"   # keep one copy only, so Spotlight and Launchpad do not list the app twice
    echo "Installed to ~/Applications/CoreGlance.app"
    ;;
zip) make_zip ;;
dmg) make_dmg ;;
release) make_zip; make_dmg ;;
esac
