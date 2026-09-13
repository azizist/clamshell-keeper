#!/bin/sh
# Phase 0 — prove the mechanism on this Mac before installing anything.
#
# `pmset disablesleep` is undocumented in `man pmset`. It is present in the
# binary and traceable through Apple's published PowerManagement and xnu source,
# but it has never been executed on this machine. This script sets it, waits for
# you to close the lid, and clears it again no matter what happens.
set -u

trap 'echo; echo "==> restoring"; sudo pmset -a disablesleep 0; ioreg -n IOPMrootDomain -r -d 1 | grep SleepDisabled' EXIT INT TERM

echo "Before:"
pmset -g ps | head -2
ioreg -n IOPMrootDomain -r -d 1 | grep SleepDisabled || echo '  "SleepDisabled" = (unset)'
BEFORE="$(pmset -g log | grep -c "Clamshell Sleep" || true)"

echo
echo "==> setting disablesleep 1"
sudo pmset -a disablesleep 1
ioreg -n IOPMrootDomain -r -d 1 | grep SleepDisabled

cat <<'MSG'

Now, with the charger UNPLUGGED and the external monitor connected:
  1. close the lid
  2. wait about 90 seconds
  3. open it again, and press Return here
MSG
read -r _

AFTER="$(pmset -g log | grep -c "Clamshell Sleep" || true)"
echo
if [ "$AFTER" -gt "$BEFORE" ]; then
	echo "RESULT: it still slept ($BEFORE -> $AFTER clamshell sleeps). Mechanism does NOT work — stop here."
else
	echo "RESULT: no new clamshell sleep. Mechanism confirmed — safe to install."
fi
pmset -g log | grep -i "clamshell sleep" | tail -3
