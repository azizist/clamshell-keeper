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
# Wait for the old instance to actually exit. bootout returns as soon as the
# signal is sent, and bootstrapping into a domain that is still draining fails
# with "Bootstrap failed: 5: Input/output error" — which is what made the first
# two reinstalls fail and a later retry succeed.
launchctl bootout --wait "system/$LABEL" 2>/dev/null || launchctl bootout "system/$LABEL" 2>/dev/null || true
# launchd creates the socket itself and will not bind over a leftover one.
rm -f /var/run/clamshellkeeper.sock
launchctl enable "system/$LABEL" 2>/dev/null || true
attempt=0
until launchctl bootstrap system "$PLIST" 2>/dev/null; do
	attempt=$((attempt + 1))
	if [ "$attempt" -ge 10 ]; then
		echo "bootstrap still failing after $attempt attempts:" >&2
		launchctl bootstrap system "$PLIST" >&2
		exit 1
	fi
	sleep 1
done

sleep 1
echo "==> state after install (expect SleepDisabled = No)"
ioreg -n IOPMrootDomain -r -d 1 | grep SleepDisabled || echo "  (key absent — also fine)"

echo "==> restarting the menu bar app"
/usr/bin/pkill -x ClamshellKeeper 2>/dev/null || true
sleep 1
/bin/launchctl asuser "$SOCK_UID" /usr/bin/open -a /Applications/ClamshellKeeper.app || true

echo
echo "Installed. ClamshellKeeper is running in the menu bar."
echo "Uninstall any time: sudo /usr/local/libexec/clamshellkeeper-uninstall.sh"
