import Foundation

// clamshellkeeperd — the only thing on this machine that writes SleepDisabled.
//
// Runs as a root LaunchDaemon with RunAtLoad + KeepAlive. It has no window
// server, no AppKit, and no user session; every sensor it uses is IOKit or
// SystemConfiguration for exactly that reason.

setvbuf(stdout, nil, _IOLBF, 0)
Log.info("clamshellkeeperd \(HelperVersion.string) starting (uid \(getuid()))")

guard getuid() == 0 else {
    Log.error("must run as root")
    exit(1)
}

// Clear the flag before exiting, so that `launchctl bootout`, a shutdown, or a
// reinstall can never leave a Mac that is unable to sleep.
for signalNumber in [SIGTERM, SIGINT] {
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
    source.setEventHandler {
        Keeper.shared.shutdown()
        exit(0)
    }
    source.resume()
    SignalSources.retained.append(source)
}

enum SignalSources {
    nonisolated(unsafe) static var retained: [DispatchSourceSignal] = []
}

Keeper.shared.start()

let server = Server()
server.start()

// IOKit notification ports are attached to the main run loop; the main dispatch
// queue is serviced by it too, so every timer, socket source and IOKit callback
// runs on one thread and the state machine needs no locking.
CFRunLoopRun()
