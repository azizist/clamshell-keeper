#!/bin/sh
# Builds the menu bar app, the root helper, and a .pkg — no Xcode project.
# Order matters: the app bundle is signed last, because any write into it
# after signing breaks the seal.
set -eu

cd "$(dirname "$0")"

APP_ID="com.azizzet.clamshellkeeper"
HELPER_ID="com.azizzet.clamshellkeeper.helper"
VERSION="1.1"
SDK="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
TARGET="arm64-apple-macos13.0"   # floor set by SMAppService; not swiftc's 26.0 default

ROOT="build/root"
APP="$ROOT/Applications/ClamshellKeeper.app"

rm -rf build dist
mkdir -p "$APP/Contents/MacOS" "$ROOT/Library/LaunchDaemons" "$ROOT/usr/local/libexec" dist

echo "==> Info.plist"
cp Resources/Info.plist "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> menu bar app"
/usr/bin/swiftc \
	-sdk "$SDK" -target "$TARGET" -swift-version 5 -O -emit-executable \
	-module-name ClamshellKeeper \
	-framework AppKit -framework IOKit -framework ServiceManagement \
	-Xlinker -dead_strip \
	-o "$APP/Contents/MacOS/ClamshellKeeper" \
	Sources/Shared/*.swift Sources/App/*.swift

echo "==> root helper"
# No AppKit: a system-domain LaunchDaemon has no window server session.
/usr/bin/swiftc \
	-sdk "$SDK" -target "$TARGET" -swift-version 5 -O -emit-executable \
	-module-name clamshellkeeperd \
	-framework Foundation -framework IOKit -framework SystemConfiguration \
	-Xlinker -dead_strip \
	-o "$ROOT/usr/local/libexec/clamshellkeeperd" \
	Sources/Shared/*.swift Sources/Helper/*.swift

echo "==> launchd plist + uninstaller"
cp "Resources/$HELPER_ID.plist" "$ROOT/Library/LaunchDaemons/$HELPER_ID.plist"
plutil -lint "$ROOT/Library/LaunchDaemons/$HELPER_ID.plist" >/dev/null
# A copy that survives dragging the app to the Trash.
cp uninstall.sh "$ROOT/usr/local/libexec/clamshellkeeper-uninstall.sh"

chmod 755 "$APP/Contents/MacOS/ClamshellKeeper" \
	"$ROOT/usr/local/libexec/clamshellkeeperd" \
	"$ROOT/usr/local/libexec/clamshellkeeper-uninstall.sh"
chmod 644 "$APP/Contents/Info.plist" "$ROOT/Library/LaunchDaemons/$HELPER_ID.plist"

echo "==> ad-hoc signing"
# --deep is deprecated for signing since macOS 13 and there is no nested code.
# An explicit --identifier keeps the designated requirement stable across
# rebuilds even though an ad-hoc signature has no Team ID.
codesign --force --sign - --identifier "$HELPER_ID" "$ROOT/usr/local/libexec/clamshellkeeperd"
codesign --force --sign - --identifier "$APP_ID" "$APP"
codesign --verify --strict "$APP"

echo "==> package"
chmod +x scripts/postinstall
/usr/bin/pkgbuild \
	--root "$ROOT" \
	--identifier "$APP_ID.pkg" \
	--version "$VERSION" \
	--install-location / \
	--scripts scripts \
	--ownership recommended \
	"dist/ClamshellKeeper-$VERSION.pkg" >/dev/null

echo
echo "Built:"
echo "  dist/ClamshellKeeper-$VERSION.pkg    (double-click, or: sudo installer -pkg dist/ClamshellKeeper-$VERSION.pkg -target /)"
echo "  sudo ./install.sh                    (same result, from the staged tree)"
