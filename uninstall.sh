#!/bin/sh
# sudo ./uninstall.sh
#
# Clearing the power setting comes FIRST, before anything that could clear it is
# removed. Removing the helper while SleepDisabled is on would leave a Mac that
# never sleeps and nothing left to fix it.
set -u

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo: sudo ./uninstall.sh" >&2; exit 1; }

LABEL="com.azizzet.clamshellkeeper.helper"

echo "==> restoring normal sleep"
/usr/bin/pmset -a disablesleep 0 || true

echo "==> unloading helper"
/bin/launchctl bootout "system/$LABEL" 2>/dev/null || true

echo "==> quitting the app"
/usr/bin/pkill -x ClamshellKeeper 2>/dev/null || true

echo "==> removing files"
rm -f "/Library/LaunchDaemons/$LABEL.plist"
rm -f /usr/local/libexec/clamshellkeeperd
rm -rf /Applications/ClamshellKeeper.app
rm -f /var/log/clamshellkeeper.log
rm -f /var/run/clamshellkeeper.sock
/usr/sbin/pkgutil --forget com.azizzet.clamshellkeeper.pkg >/dev/null 2>&1 || true

echo "==> verifying (both lines should say sleep is enabled)"
ioreg -n IOPMrootDomain -r -d 1 | grep SleepDisabled || echo "  SleepDisabled: key absent (good)"
pmset -g | grep -i sleepdisabled || echo "  pmset -g: no SleepDisabled line (good)"

echo
echo "Removed. If 'Start at Login' was on, clear the leftover entry in"
echo "System Settings > General > Login Items."
rm -f /usr/local/libexec/clamshellkeeper-uninstall.sh
