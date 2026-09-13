import Foundation

/// The single place that changes system state.
///
/// `SleepDisabled` (set via `pmset -a disablesleep`) is the only lever that
/// actually permits lid-closed operation on battery, and it is a sledgehammer:
/// it is system-wide, it persists across reboot in
/// /Library/Preferences/com.apple.PowerManagement.plist, and it blocks *every*
/// sleep path including the kernel's low-battery hibernate and thermal
/// emergency. That is why this function is private to the helper, why the
/// helper clears it at startup and at exit, and why every write is verified by
/// reading the kernel back.
enum Mechanism {

    /// `-a` is deliberate. `disablesleep` is a system power setting and is not
    /// scoped by power source: `-b` parses fine and is then silently ignored,
    /// which would mislead anyone reading this later.
    private static let pmset = "/usr/bin/pmset"

    @discardableResult
    static func apply(_ disableSleep: Bool) -> Bool {
        for attempt in 1...3 {
            spawnPmset(disableSleep)
            usleep(150_000)
            if Sensors.sleepDisabled() == disableSleep { return true }
            Log.warn("pmset disablesleep \(disableSleep ? 1 : 0) did not take (attempt \(attempt)/3)")
        }
        Log.error("FAILED to set SleepDisabled=\(disableSleep) after 3 attempts")
        return false
    }

    private static func spawnPmset(_ disableSleep: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pmset)
        process.arguments = ["-a", "disablesleep", disableSleep ? "1" : "0"]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            Log.error("could not run pmset: \(error)")
        }
    }
}

enum Log {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static func emit(_ level: String, _ message: String) {
        // Deliberately logs uids and counts, never usernames or display
        // vendor/model/serial. Risk area: data handling.
        print("\(formatter.string(from: Date())) [\(level)] \(message)")
        fflush(stdout)
    }

    static func info(_ m: String) { emit("info", m) }
    static func warn(_ m: String) { emit("warn", m) }
    static func error(_ m: String) { emit("error", m) }
}
