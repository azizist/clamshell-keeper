import Foundation

// Wire protocol and install-time constants shared by the app and the root helper.
//
// The client may only ever send one of three verbs. No string, path, argv or
// command crosses this boundary: the helper never takes a pmset argument from
// the client, it only takes a request and two bounded integers.
enum Wire {
    static let socketPath = "/var/run/clamshellkeeper.sock"
    static let launchdSocketName = "Listeners"
    static let helperLabel = "com.azizzet.clamshellkeeper.helper"
    static let appBundleID = "com.azizzet.clamshellkeeper"

    /// Hard ceiling on a single protocol line. Anything longer is a protocol
    /// violation and the connection is dropped.
    static let maxLineBytes = 64

    /// The client must re-send ARM at least this often or the grant goes stale.
    static let heartbeatInterval: TimeInterval = 20
    /// Helper-side deadman: a grant older than this is dead, app or no app.
    static let heartbeatTimeout: TimeInterval = 60
    /// Backstop cap on one continuous armed session.
    static let sessionCap: TimeInterval = 8 * 3600

    static let maxExternalDisplays = 16
    static let maxBatteryFloor = 50

    enum Request {
        /// Arm (or renew) with the client's view of the world.
        case arm(external: Int, batteryFloor: Int)
        case disarm
        case status

        /// Strict parser. Anything unexpected is rejected rather than coerced.
        static func parse(_ line: String) -> Request? {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            switch parts.first {
            case "DISARM" where parts.count == 1:
                return .disarm
            case "STATUS" where parts.count == 1:
                return .status
            case "ARM" where parts.count == 3:
                guard let ext = Int(parts[1]), let floor = Int(parts[2]),
                      (0...maxExternalDisplays).contains(ext),
                      (0...maxBatteryFloor).contains(floor)
                else { return nil }
                return .arm(external: ext, batteryFloor: floor)
            default:
                return nil
            }
        }

        var line: String {
            switch self {
            case .arm(let ext, let floor): return "ARM \(ext) \(floor)"
            case .disarm: return "DISARM"
            case .status: return "STATUS"
            }
        }
    }

    /// One JSON line, sent in reply to every request.
    struct Status: Codable {
        var armed: Bool
        var sleepDisabled: Bool
        /// Why the helper is not armed (empty when it is). Shown in the menu.
        var reason: String
        var lidClosed: Bool
        var externalDisplays: Int   // -1 means the helper could not tell
        var onAC: Bool
        var batteryPercent: Int     // -1 means unknown
        var helperVersion: String
    }
}

extension Wire {
    /// Builds the AF_UNIX address once, for both ends of the connection.
    private static func socketAddress() -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutablePointer(to: &address.sun_path) { path in
            path.withMemoryRebound(to: CChar.self, capacity: capacity) { characters in
                _ = socketPath.withCString { strlcpy(characters, $0, capacity) }
            }
        }
        return address
    }

    /// Hands the socket address to bind(2) or connect(2).
    static func withSocketAddress<T>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        var address = socketAddress()
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }
}
