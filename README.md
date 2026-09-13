# ClamshellKeeper

Use this MacBook with the lid closed on an external monitor **without the charger plugged in**.

macOS normally refuses: powerd grants "clamshell awake" only when it sees *DesktopMode **and** AC*. On battery it arms clamshell sleep regardless of how many monitors are attached. Its own log says so:

```
DesktopMode check on Battery 0
EvaluateClamshell. Disable : 0 because {DesktopMode with AC: 0, assertions 0
[sleepWake] Entering Sleep state due to 'Clamshell Sleep'
```

ClamshellKeeper flips that on request, and — more importantly — takes it back automatically the moment it should not be on.

You do **not** need anything to turn the built-in screen off. When the lid closes, WindowServer removes the internal display and powerd powers the panel down. That part already behaves like Windows; the only thing missing was staying awake.

---

## Requirements

Built and tested on **Apple Silicon** (M2 Pro) running **macOS 26.5.2**. Nothing
else has been tried.

The binaries have a macOS 13.0 deployment target, so they should launch further
back than that, but two of the load-bearing pieces are not contractual:

- **`pmset disablesleep` is undocumented.** It is absent from `man pmset`,
  present in the binary, and traceable through Apple's published
  `PowerManagement` and `xnu` sources. Apple can change or remove it in any
  update. Every write is verified by reading `IOPMrootDomain` back, so a change
  surfaces as a visible "arm failed" rather than a Mac that quietly sleeps in
  your bag.
- **The helper's display check uses `IOMobileFramebufferShim`**, a private,
  undocumented, Apple-Silicon-specific IOKit class. On an Intel Mac — or after
  an OS update that renames it — the check returns *unknown* rather than
  *absent*, and the predicate fails closed: the tool simply never arms. It will
  not misbehave, it just will not work until that check is reworked for the
  platform.

Running this on Intel therefore needs a different display check in
`Sources/Helper/Sensors.swift`; nothing else in the design is
architecture-specific.

## Test

```bash
./test.sh
```

Exercises the protocol parser (the only untrusted input the root helper accepts)
and every branch of the arm predicate, including each fail-closed path. Needs no
root and touches no machine state.

## Install

```bash
./build.sh
sudo ./install.sh
```

or double-click `dist/ClamshellKeeper-1.0.pkg` (equivalently `sudo installer -pkg dist/ClamshellKeeper-1.0.pkg -target /`).

**Run `./phase0-test.sh` first if you have not already.** It proves the underlying mechanism works on this Mac and puts everything back afterwards, whatever happens.

Open ClamshellKeeper from `/Applications`; it lives in the menu bar with no Dock icon.

## Use

Tick **Keep awake with lid closed**. That is a standing preference, not a one-shot:

- while a monitor is attached, the Mac stays awake with the lid closed, on battery;
- unplug the monitor and normal sleep comes straight back;
- plug it in again and the mode resumes on its own.

The menu's first line always tells you the real state, read back from the kernel — displays, battery, and whether lid-closed mode is actually active (with the reason when it is not).

**Restore sleep below 20% battery** is off by default, per the design decision on this project. See Safety.

## Uninstall

```bash
sudo /usr/local/libexec/clamshellkeeper-uninstall.sh
```

It restores normal sleep *first*, then removes everything, then proves the flag is gone. A copy lives outside the app bundle on purpose, so it still works after you drag the app to the Trash.

---

## How it works

```
/Applications/ClamshellKeeper.app     menu bar, user session, no privilege
        │  unix socket, mode 0600, owned by you
        │  ARM <displays> <floor> / DISARM / STATUS
        ▼
/usr/local/libexec/clamshellkeeperd   root LaunchDaemon, sole writer of SleepDisabled
        │
        ▼  pmset -a disablesleep 0|1, verified by reading IOPMrootDomain back
```

The lever is `pmset -a disablesleep` (`SleepDisabled`). It is undocumented in `man pmset` but present in the binary and traceable through Apple's published `PowerManagement` and `xnu` sources. It is also a sledgehammer, which is what the rest of this design is about:

- it is **system-wide** (`-b` parses and is then silently ignored — always `-a`);
- it **persists across reboot**, in `/Library/Preferences/com.apple.PowerManagement.plist`;
- it blocks **every** sleep path, including the kernel's low-battery hibernate and thermal-emergency sleep.

So the helper, not the app, is the authority:

| Guarantee | Mechanism |
|---|---|
| Never stuck on after a crash, panic or reboot | The helper's first act on every load is an unconditional `disablesleep 0`, plus a 10 s tick that clears the flag any time it is set without a live grant. |
| Never stuck on after uninstall | SIGTERM handler clears it before exit; the uninstaller clears it before removing anything. |
| Dies with the app | The app re-sends `ARM` every 20 s. A grant older than 60 s is dead — crash, kill, logout, anything. |
| Never armed at the login window | Arming requires a console user whose uid matches the connecting process. |
| Never armed without a monitor | Both sides must agree: the app counts external displays with CoreGraphics, and the helper independently checks IOKit. Either saying "no" or "cannot tell" disarms. |

The helper deliberately uses no CoreGraphics: every `CG*` display call is a WindowServer RPC, and from a system daemon it fails by reporting *success with zero displays* — indistinguishable from "no monitor attached", in the one direction that would leave a hot Mac awake in a bag.

## Safety — read this bit

- **While lid-closed mode is active, the Mac cannot emergency-sleep.** Not on thermal emergency, not on critical battery. That is inherent to the only mechanism that works, not a shortcut taken here. The mitigations are the ones in the table above: the mode stays on only while an app you can see keeps confirming a monitor is attached.
- **The battery floor is off by default** (your call). With it off, running flat while armed ends in an unclean shutdown rather than a hibernate — unsaved work is lost and APFS replays its journal. One tick in the menu turns it on at 20%.
- **Thermal detection is best-effort.** This Mac publishes no thermal warning level at all (`pmset -g therm` → "No thermal warning level has been recorded"), so treat the thermal disarm as a bonus, never as the safety net.
- **Emergency reset**, also in the menu under *Copy emergency reset command*:

  ```bash
  sudo pmset -a disablesleep 0
  ```

- **Security, stated plainly.** The socket is owned by you with mode 0600 and the helper checks `getpeereid()` against the console user, so no other account can reach it. Because the build is ad-hoc signed there is no Team ID to pin, so another program running *as you* could in principle talk to the helper. What that buys an attacker is bounded by the same predicate as everything else — it cannot hold the Mac awake with no monitor attached, past a logout, or beyond 60 seconds of silence. It is not a strong boundary and is not described as one. This is why there is no `sudoers` NOPASSWD rule: that would have been an unbounded, invisible, permanent version of the same thing.

## Troubleshooting

```bash
# is the helper running?
sudo launchctl print system/com.azizzet.clamshellkeeper.helper | head -20

# what does the kernel actually think?
ioreg -n IOPMrootDomain -r -d 1 | grep -E "SleepDisabled|AppleClamshellState"

# watch the decision live while you close the lid
log stream --predicate 'process == "powerd" OR process == "kernel"' --info \
  | grep -E "EvaluateClamshell|Clamshell Sleep|setClamShellSleepDisable"

# helper log
sudo tail -f /var/log/clamshellkeeper.log

# did it sleep when it should not have?
pmset -g log | grep -i "clamshell sleep" | tail
```

*Menu says "Helper not running"* — the daemon is not loaded, or the socket is owned by a different uid. Re-run `sudo ./install.sh`.

*Screens still blank after 20 minutes* — expected, and unrelated. `displaysleep` is a separate timer; the system stays awake underneath. Change it in System Settings if you don't want it.

## Layout

```
Sources/Shared/Protocol.swift     wire protocol, shared by both binaries
Sources/App/                      menu bar app (AppKit, CoreGraphics, IOPS)
Sources/Helper/                   root daemon (IOKit + SystemConfiguration only)
Sources/Helper/Policy.swift       the arm predicate, as a pure function
Tests/                            protocol + predicate tests
Resources/                        Info.plist, LaunchDaemon plist
build.sh test.sh install.sh uninstall.sh phase0-test.sh
```

Built with `swiftc` directly — no Xcode project. Deployment target is macOS 13.0 (the floor set by `SMAppService`, used for Start at Login).
