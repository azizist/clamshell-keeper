import Foundation

/// Unix domain socket server for the menu bar app.
///
/// Access control is kernel-enforced, not negotiated: launchd creates the
/// socket owned by the installing user with mode 0600, so nothing else on the
/// machine can even open it, and every connection is additionally checked with
/// `getpeereid()` against the current console user.
///
/// This is deliberately not XPC. With an ad-hoc signature there is no Team ID
/// to pin, so XPC peer validation would reduce to the same uid check while
/// adding a Mach service name that any process can look up.
final class Server {

    private var listeners: [DispatchSourceRead] = []
    private var connections: [Int32: Connection] = [:]

    private final class Connection {
        let fd: Int32
        let uid: uid_t
        var buffer = Data()
        var source: DispatchSourceRead?
        init(fd: Int32, uid: uid_t) { self.fd = fd; self.uid = uid }
    }

    func start() {
        let fds = launchdSockets() ?? [selfBoundSocket()].compactMap { $0 }
        guard !fds.isEmpty else {
            Log.error("no listening socket — the app will not be able to talk to the helper")
            return
        }
        for fd in fds { listen(on: fd) }
    }

    /// The normal path: launchd made and owns the socket.
    private func launchdSockets() -> [Int32]? {
        // The parameter is a non-optional pointer-to-pointer, so it needs a
        // placeholder to point at; launchd replaces it with its own malloc'd
        // array, which is ours to free.
        var placeholder: Int32 = 0
        return withUnsafeMutablePointer(to: &placeholder) { initial -> [Int32]? in
            var pointer = initial
            var count: size_t = 0
            guard launch_activate_socket(Wire.launchdSocketName, &pointer, &count) == 0,
                  count > 0, pointer != initial
            else { return nil }
            defer { free(pointer) }
            return (0..<count).map { pointer[$0] }
        }
    }

    /// Fallback for running the helper by hand outside launchd (testing).
    /// Applies the same ownership and mode launchd would.
    private func selfBoundSocket() -> Int32? {
        unlink(Wire.socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        let bound = Wire.withSocketAddress { address, length in
            bind(fd, address, length)
        }
        guard bound == 0, Darwin.listen(fd, 4) == 0 else { close(fd); return nil }
        if let uid = Sensors.consoleUID() { chown(Wire.socketPath, uid, 0) }
        chmod(Wire.socketPath, 0o600)
        Log.info("bound socket directly (not launched by launchd)")
        return fd
    }

    private func listen(on fd: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in self?.accept(on: fd) }
        source.resume()
        listeners.append(source)
    }

    private func accept(on listenFD: Int32) {
        let fd = Darwin.accept(listenFD, nil, nil)
        guard fd >= 0 else { return }

        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, let console = Sensors.consoleUID(), uid == console else {
            Log.warn("rejected connection from uid \(uid)")
            close(fd)
            return
        }

        let connection = Connection(fd: fd, uid: uid)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in self?.read(connection) }
        source.setCancelHandler { close(fd) }
        connection.source = source
        connections[fd] = connection
        source.resume()
    }

    private func read(_ connection: Connection) {
        var chunk = [UInt8](repeating: 0, count: 256)
        let count = Darwin.read(connection.fd, &chunk, chunk.count)
        guard count > 0 else { drop(connection); return }
        connection.buffer.append(contentsOf: chunk[0..<count])

        while let newline = connection.buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = connection.buffer[connection.buffer.startIndex..<newline]
            connection.buffer.removeSubrange(connection.buffer.startIndex...newline)
            guard lineData.count <= Wire.maxLineBytes,
                  let line = String(data: Data(lineData), encoding: .utf8),
                  let request = Wire.Request.parse(line.trimmingCharacters(in: .whitespaces))
            else {
                Log.warn("protocol violation — dropping connection")
                drop(connection)
                return
            }
            handle(request, on: connection)
        }

        // A client that sends an unterminated flood is not a client we keep.
        if connection.buffer.count > Wire.maxLineBytes { drop(connection) }
    }

    private func handle(_ request: Wire.Request, on connection: Connection) {
        let status: Wire.Status
        switch request {
        case .arm(let external, let floor):
            status = Keeper.shared.requestArm(external: external, batteryFloor: floor, uid: connection.uid)
        case .disarm:
            status = Keeper.shared.requestDisarm()
        case .status:
            status = Keeper.shared.status()
        }
        guard var payload = try? JSONEncoder().encode(status) else { return }
        payload.append(UInt8(ascii: "\n"))
        payload.withUnsafeBytes { bytes in
            _ = Darwin.write(connection.fd, bytes.baseAddress, bytes.count)
        }
    }

    private func drop(_ connection: Connection) {
        connection.source?.cancel()
        connections.removeValue(forKey: connection.fd)
        // The grant is not revoked here: a dropped connection is covered by the
        // heartbeat timeout, so a flapping socket cannot toggle system state.
    }
}
