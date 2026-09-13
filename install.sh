#!/bin/sh
# sudo ./install.sh — installs the staged tree built by ./build.sh.
set -eu

cd "$(dirname "$0")"

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo: sudo ./install.sh" >&2; exit 1; }
[ -d build/root ] || { echo "Run ./build.sh first." >&2; exit 1; }

LABEL="com.azizzet.clamshellkeeper.helper"
PLIST="/Library/LaunchDaemons/$LABEL.plist"

# The invoking (console) user is the only account allowed to reach the helper.
SOCK_UID="${SUDO_UID:-$(stat -f %u /dev/console)}"

echo "==> copying payload"
rm -rf /Applications/ClamshellKeeper.app
ditto build/root/Applications/ClamshellKeeper.app /Applications/ClamshellKeeper.app
install -d -o root -g wheel -m 755 /usr/local/libexec
install -o root -g wheel -m 755 build/root/usr/local/libexec/clamshellkeeperd /usr/local/libexec/clamshellkeeperd
install -o root -g wheel -m 755 build/root/usr/local/libexec/clamshellkeeper-uninstall.sh /usr/local/libexec/clamshellkeeper-uninstall.sh
cp "build/root/Library/LaunchDaemons/$LABEL.plist" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :Sockets:Listeners:SockPathOwner $SOCK_UID" "$PLIST"
chown -R root:wheel /Applications/ClamshellKeeper.app
chown root:wheel "$PLIST"
chmod 644 "$PLIST"

touch /var/log/clamshellkeeper.log
chown root:wheel /var/log/clamshellkeeper.log
chmod 640 /var/log/clamshellkeeper.log

echo "==> loading helper"
launchctl bootout "system/$LABEL" 2>/dev/null || true
launchctl enable "system/$LABEL" 2>/dev/null || true
launchctl bootstrap system "$PLIST"

sleep 1
echo "==> state after install (expect SleepDisabled = No)"
ioreg -n IOPMrootDomain -r -d 1 | grep SleepDisabled || echo "  (key absent — also fine)"

echo
echo "Installed. Open ClamshellKeeper from /Applications; it lives in the menu bar."
echo "Uninstall any time: sudo /usr/local/libexec/clamshellkeeper-uninstall.sh"
