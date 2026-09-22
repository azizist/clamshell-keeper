# ClamshellKeeper

Two things macOS won't do on its own:

1. **Use the MacBook with the lid closed on an external monitor without the charger plugged in.**
2. **Turn the built-in display off while the lid is open**, so the external monitor is the only screen — the equivalent of Windows' "Show only on 2".

macOS normally refuses: powerd grants "clamshell awake" only when it sees *DesktopMode **and** AC*. On battery it arms clamshell sleep regardless of how many monitors are attached. Its own log says so:

```
DesktopMode check on Battery 0
EvaluateClamshell. Disable : 0 because {DesktopMode with AC: 0, assertions 0
[sleepWake] Entering Sleep state due to 'Clamshell Sleep'
```

ClamshellKeeper flips that on request, and — more importantly — takes it back automatically the moment it should not be on.

The second feature exists because macOS 27 has no setting for it. The Displays
pane's entire vocabulary is *Use as* / *Extended* / *Mirror* / *Stop Mirroring* —
there is no "turn this one off", and closing the lid is the only sanctioned way
to stop using the built-in panel. Every tool that does offer it (BetterDisplay,
Lunar's BlackOut, displayplacer) reaches for the same private SkyLight call, and
so does this.

Note the two features are unrelated machinery: one is power management owned by
a root helper, the other is display configuration owned by the menu bar app.
Nothing is shared between them but the menu.

---

## Requirements

Built and tested on **Apple Silicon** (M2 Pro, Mac14,9) running **macOS 26.5.2
and macOS 27.0** (build 26A428). Nothing else has been tried.

The binaries have a macOS 13.0 deployment target, so they should launch further
back than that, but three of the load-bearing pieces are not contractual:

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

- **`CGSConfigureDisplayEnabled` is a private SkyLight SPI** (re-exported
  through public CoreGraphics as `SLSConfigureDisplayEnabled`). There is no
  public API that disables a display at all. If an OS update removes the symbol,
  the menu item greys out and says so rather than half-working.

Running this on Intel therefore needs a different display check in
`Sources/Helper/Sensors.swift`; nothing else in the design is
architecture-specific.

One hardware caveat, from BetterDisplay's tracker rather than from here: on
**entry-level M3 Macs** restoring the built-in panel can require a reboot, and
upstream's fix was to refuse the operation on that hardware. This machine
(M2 Pro) is outside that class, and the probes below were run on it directly.

## Test

```bash
./test.sh
```

Exercises the protocol parser (the only untrusted input the root helper accepts)
and every branch of the arm predicate, including each fail-closed path. Needs no
root and touches no machine state.

## Install

### From source (recommended)

```bash
./build.sh
sudo ./install.sh
```

This also produces `dist/ClamshellKeeper-1.0.pkg`, which you can double-click, or
install with `sudo installer -pkg dist/ClamshellKeeper-1.0.pkg -target /`.

**Run `./phase0-test.sh` first if you have not already.** It proves the underlying
mechanism works on this Mac and puts everything back afterwards, whatever happens.

Open ClamshellKeeper from `/Applications`; it lives in the menu bar with no Dock icon.

### From a downloaded release

The package is **not signed or notarized** — doing so requires a paid Apple
Developer ID, and there is no free path to it. A package built on your own Mac
installs without complaint because it never gets a `com.apple.quarantine`
attribute. One you *download* does, and Gatekeeper will refuse it as coming from
an unidentified developer.

So a downloaded `.pkg` needs one of these:

```bash
xattr -d com.apple.quarantine ~/Downloads/ClamshellKeeper-1.0.pkg
```

…or right-click the package in Finder, choose **Open**, then **Open anyway**.

Building from source avoids the question entirely, and has the advantage that
you can read what you are about to give a root LaunchDaemon to.

### What gets installed

```
/Applications/ClamshellKeeper.app                                 menu bar app
/usr/local/libexec/clamshellkeeperd                               root helper
/Library/LaunchDaemons/com.azizzet.clamshellkeeper.helper.plist   loads the helper at boot
/usr/local/libexec/clamshellkeeper-uninstall.sh                   survives deleting the app
/var/log/clamshellkeeper.log                                      helper log, root-only
```

## Use

Tick **Keep awake with lid closed**. That is a standing preference, not a one-shot:

- while a monitor is attached, the Mac stays awake with the lid closed, on battery;
- unplug the monitor and normal sleep comes straight back;
- plug it in again and the mode resumes on its own.

The menu's first line always tells you the real state, read back from the kernel — displays, battery, and whether lid-closed mode is actually active (with the reason when it is not).

**Restore sleep below 20% battery** is off by default, per the design decision on this project. See Safety.

### Use external display only

Tick **Use external display only** to turn the built-in panel off with the lid
open. The menu item is greyed out unless it is safe to engage: the private API
resolved, the lid is open, and there is a confirmed external display.

The first time, a dialog appears on the external asking you to confirm, and
reverts on its own after 15 seconds. That is not ceremony — it is the only
protection against the one failure nothing can detect: the external going dark
*without disconnecting* (a monitor input switch, a KVM, its own power button on
a link that stays up). No event fires in that case, so no code runs, and both
panels are black. The countdown is what gets you out. Tick **Don't ask again**
once you trust your setup.

Unlike the sleep toggle, this one is **not remembered across restarts**. A black
panel must never be something that comes back on its own at login while an
external is still negotiating its link.

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

### And for the built-in display

| Guarantee | Mechanism |
|---|---|
| Comes back if the monitor is unplugged | The app re-enables within ~250ms of the reconfiguration event — deliberately far faster than the 2.5s confirmation the power path uses, because the cost of being slow here is a black screen rather than a bit of extra battery. |
| Never sleeps while disabled | The built-in is restored on `willSleepNotification`, before the machine sleeps. Sleep and clamshell transitions renumber display IDs, and a disabled display appears in no public list, so waking up still disabled is the hardest state to get out of. Costs a flicker on wake; removes the failure mode. |
| Recovers even if an event is missed | Every reconcile is idempotent and also runs on the 20s heartbeat, so a dropped reconfiguration callback self-heals rather than sticking. |
| Comes back if the app crashes or is force-quit | The change is made with `kCGConfigureForAppOnly`, which macOS reverts when the process dies. **Verified on this machine under `kill -9`:** the panel returned within one second, twice. |
| Never survives a reboot | Nothing is written to disk. `kCGConfigurePermanently` is the only option that would persist it, and it is never passed. A reboot is therefore a guaranteed way out. |
| Never engages without a real monitor | CoreGraphics reports Sidecar, AirPlay and DisplayLink as "external". Engaging additionally requires the helper's independent IOKit count of physically attached panels to agree. |
| Never gives up on restoring | The re-enable path retries, then escalates to `CGRestorePermanentDisplayConfiguration()`. The failure latch that stops a disable retry storm applies to the disable direction only. |

**If you ever end up with no picture at all:** unplug or replug the external
(the app restores the built-in), or close and reopen the lid, or reboot — a
reboot always works, because the state only ever lived in WindowServer's memory.

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
Sources/App/InternalDisplay.swift the only file that touches a private API
Sources/App/DisplayPolicy.swift   the built-in-display predicate, pure
Sources/Helper/                   root daemon (IOKit + SystemConfiguration only)
Sources/Helper/Policy.swift       the arm predicate, as a pure function
Tests/                            protocol + predicate tests
Resources/                        Info.plist, LaunchDaemon plist
build.sh test.sh install.sh uninstall.sh phase0-test.sh
```

Built with `swiftc` directly — no Xcode project. Deployment target is macOS 13.0 (the floor set by `SMAppService`, used for Start at Login).
