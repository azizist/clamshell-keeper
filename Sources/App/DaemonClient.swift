import Foundation

/// Talks to the root helper over its unix socket.
///
/// One short-lived connection per request. The helper's grant is held by the
/// heartbeat, not by the connection, so there is no session to keep alive and
/// nothing to resynchronise after a reconnect.
final class DaemonClient {

    enum Failure: Error {
        case unreachable
        case noReply
    }

    private let queue = DispatchQueue(label: "com.azizzet.clamshellkeeper.client")

    /// Synchronous variant for app termination, where the main queue is about
    /// to stop being serviced and an async completion would never be delivered.
    @discardableResult
    func sendBlocking(_ request: Wire.Request) -> Bool {
        (try? roundTrip(request)) != nil
    }

    func send(_ request: Wire.Request, completion: @escaping (Result<Wire.Status, Error>) -> Void) {
        queue.async {
            let result = Result { try self.roundTrip(request) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func roundTrip(_ request: Wire.Request) throws -> Wire.Status {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.unreachable }
        defer { close(fd) }

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let connected = Wire.withSocketAddress { address, length in
            connect(fd, address, length)
        }
        guard connected == 0 else { throw Failure.unreachable }

        let line = request.line + "\n"
        try line.withCString { pointer in
            let length = strlen(pointer)
            guard write(fd, pointer, length) == length else { throw Failure.unreachable }
        }

        var reply = Data()
        var chunk = [UInt8](repeating: 0, count: 512)
        while reply.count < 4096 {
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { break }
            reply.append(contentsOf: chunk[0..<count])
            if reply.last == UInt8(ascii: "\n") { break }
        }
        guard !reply.isEmpty else { throw Failure.noReply }
        return try JSONDecoder().decode(Wire.Status.self, from: reply)
    }
}
