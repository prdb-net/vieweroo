import Darwin
import Foundation
import Network
import SystemConfiguration

/// A short-lived, read-only HTTP origin for the one movie selected in the player.
/// Listener state and the connection registry are confined to queue.
final class AirPlayMediaServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "net.prdb.vieweroo.airplay")
    private let movie: URL
    private let path: String
    private let contentType: String
    private let host: String
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var stopped = false
    private let stallTimeout: TimeInterval

    /// A receiver that stops reading for `stallTimeout` loses its connection. Receivers
    /// request the remaining bytes again with a range request when playback continues.
    init(movie: URL, host: String? = nil, stallTimeout: TimeInterval = 120) throws {
        self.movie = movie
        self.stallTimeout = stallTimeout
        guard let address = host ?? Self.lanHost() else { throw URLError(.notConnectedToInternet) }
        self.host = address
        let ext = movie.pathExtension.lowercased()
        switch ext {
        case "mov": contentType = "video/quicktime"
        case "mp4", "m4v": contentType = "video/mp4"
        default: throw CocoaError(.fileReadUnsupportedScheme)
        }
        path = "/\(UUID().uuidString)/video.\(ext)"
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        if host == "127.0.0.1" { parameters.requiredInterfaceType = .loopback }
        listener = try NWListener(using: parameters)
    }

    private static func lanHost() -> String? {
        // A numeric LAN address also works on receivers without a .local HTTP resolver.
        if let store = SCDynamicStoreCreate(nil, "Vieweroo AirPlay" as CFString, nil, nil),
           let state = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
           let name = state["PrimaryInterface"] as? String, name.hasPrefix("en") || name.hasPrefix("bridge"),
           let service = state["PrimaryService"] as? String,
           let ipv4 = SCDynamicStoreCopyValue(store, "State:/Network/Service/\(service)/IPv4" as CFString) as? [String: Any],
           let ip = (ipv4["Addresses"] as? [String])?.first, IPv4Address(ip) != nil { return ip }
        return (SCDynamicStoreCopyLocalHostName(nil) as String?).map { $0 + ".local" }
    }

    func start(_ completion: @escaping @Sendable (Result<URL, Error>) -> Void) {
        // Opening a movie on a mounted drive can block. Locking must still be able
        // to revoke the listener immediately.
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do {
                let source = try MovieSource(movie)
                queue.async { [self] in listen(source: source, completion: completion) }
            } catch { completion(.failure(error)) }
        }
    }

    private func listen(source: MovieSource, completion: @escaping @Sendable (Result<URL, Error>) -> Void) {
        guard !stopped else { return }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, !self.stopped else { return }
            switch state {
            case .ready:
                self.listener.stateUpdateHandler = nil
                guard let port = self.listener.port,
                      let url = URL(string: "http://\(self.host):\(port.rawValue)\(self.path)") else {
                    completion(.failure(URLError(.badURL)))
                    return
                }
                completion(.success(url))
            case .failed(let error), .waiting(let error):
                self.listener.stateUpdateHandler = nil
                completion(.failure(error))
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, !self.stopped, self.connections.count < 16 else {
                connection.cancel()
                return
            }
            let id = ObjectIdentifier(connection)
            self.connections[id] = connection
            let request = MovieRequest(connection: connection, source: source, path: self.path,
                                      contentType: self.contentType, stallTimeout: self.stallTimeout)
            request.start { [weak self] in
                self?.queue.async { [weak self] in self?.connections.removeValue(forKey: id) }
            }
        }
        listener.start(queue: queue)
    }

    func stop() {
        queue.sync {
            stopped = true
            listener.cancel()
            for connection in connections.values { connection.forceCancel() }
            connections.removeAll()
        }
    }
}

// Hold the opened file for the stream lifetime. A rename or replacement at the
// original path must never change what an existing receiver URL can retrieve.
private struct MovieSource: Sendable {
    let file: FileHandle
    let length: UInt64

    init(_ movie: URL) throws {
        file = try FileHandle(forReadingFrom: movie)
        var info = stat()
        guard fstat(file.fileDescriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        length = UInt64(info.st_size)
    }

    func read(at offset: UInt64, count: Int) -> Data? {
        var data = Data(count: count)
        let size = data.withUnsafeMutableBytes { buffer in
            pread(file.fileDescriptor, buffer.baseAddress, count, off_t(offset))
        }
        guard size > 0 else { return nil }
        data.count = size
        return data
    }
}

// Independent request queues and positional reads allow overlapping seeks.
// Send one chunk at a time so a slow receiver cannot buffer the movie in RAM.
private final class MovieRequest: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "net.prdb.vieweroo.airplay.request")
    private let source: MovieSource
    private let path: String
    private let contentType: String
    private var header = Data()
    private var receivedHeader = false
    private let stallTimeout: TimeInterval
    private var lastProgress = DispatchTime.now()

    init(connection: NWConnection, source: MovieSource, path: String, contentType: String, stallTimeout: TimeInterval) {
        self.connection = connection
        self.source = source
        self.path = path
        self.contentType = contentType
        self.stallTimeout = stallTimeout
    }

    /// Close a transfer whose receiver has not accepted data for `stallTimeout`. Otherwise
    /// the connection, its slot and the open file stay held until the player closes the stream.
    private func watchForStall() {
        let interval = max(0.05, min(stallTimeout / 4, 30))
        queue.asyncAfter(deadline: .now() + interval) { [weak self] in
            guard let self, self.connection.state == .ready else { return }
            let idle = Double(DispatchTime.now().uptimeNanoseconds - self.lastProgress.uptimeNanoseconds) / 1e9
            if idle >= self.stallTimeout { self.connection.cancel() } else { self.watchForStall() }
        }
    }

    func start(onClose: @escaping @Sendable () -> Void) {
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready: receive()
            case .failed, .cancelled:
                connection.stateUpdateHandler = nil
                connection.cancel()
                onClose()
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in
            if let self, !self.receivedHeader { self.connection.cancel() }
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [self] data, _, ended, error in
            if let data { header.append(data) }
            if header.count > 16384 { finish("431 Request Header Fields Too Large"); return }
            if let end = header.range(of: Data("\r\n\r\n".utf8)),
               let request = String(data: header[..<end.lowerBound], encoding: .isoLatin1) {
                receivedHeader = true
                respond(to: request.components(separatedBy: "\r\n"))
            } else if ended || error != nil { connection.cancel() }
            else { receive() }
        }
    }

    private func respond(to lines: [String]) {
        let request = lines.first?.split(separator: " ") ?? []
        guard request.count == 3 else { finish("400 Bad Request"); return }
        guard request[1] == path else { finish("404 Not Found"); return }
        guard request[0] == "GET" || request[0] == "HEAD" else {
            finish("405 Method Not Allowed", fields: ["Allow: GET, HEAD"])
            return
        }
        let length = source.length
        let rangeHeaders = lines.dropFirst().compactMap { line -> String? in
            let pair = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, pair[0].lowercased() == "range" else { return nil }
            return pair[1].trimmingCharacters(in: .whitespaces)
        }
        var bounds = UInt64(0)..<length
        var fields = ["Content-Type: \(contentType)", "Accept-Ranges: bytes"]
        if let value = rangeHeaders.first {
            guard rangeHeaders.count == 1, let range = Self.byteRange(value, length: length) else {
                finish("416 Range Not Satisfiable", fields: ["Content-Range: bytes */\(length)"])
                return
            }
            bounds = range
            fields.append("Content-Range: bytes \(range.lowerBound)-\(range.upperBound - 1)/\(length)")
        }
        let offset = bounds.lowerBound
        let count = bounds.upperBound - offset
        let status = rangeHeaders.isEmpty ? "200 OK" : "206 Partial Content"
        sendHead(status, fields: fields, length: count) { [self] in
            if request[0] == "HEAD" { connection.cancel() }
            else {
                lastProgress = .now()
                watchForStall()
                sendFile(at: offset, remaining: count)
            }
        }
    }

    private static func byteRange(_ value: String, length: UInt64) -> Range<UInt64>? {
        guard length > 0, value.lowercased().hasPrefix("bytes=") else { return nil }
        let parts = value.dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return nil }
        if parts[0].isEmpty {
            guard let count = UInt64(parts[1]), count > 0 else { return nil }
            return (length - min(count, length))..<length
        }
        guard let start = UInt64(parts[0]), start < length else { return nil }
        if parts[1].isEmpty { return start..<length }
        guard let end = UInt64(parts[1]), end >= start else { return nil }
        return start..<(min(length - 1, end) + 1)
    }

    private func sendFile(at offset: UInt64, remaining: UInt64) {
        guard remaining > 0,
              let data = source.read(at: offset, count: Int(min(256 * 1024, remaining))) else {
            connection.cancel()
            return
        }
        connection.send(content: data, completion: .contentProcessed { [self] error in
            guard error == nil else { connection.cancel(); return }
            lastProgress = .now()
            sendFile(at: offset + UInt64(data.count), remaining: remaining - UInt64(data.count))
        })
    }

    private func finish(_ status: String, fields: [String] = []) {
        sendHead(status, fields: fields, length: 0) { [self] in connection.cancel() }
    }

    private func sendHead(_ status: String, fields: [String], length: UInt64,
                          then: @escaping @Sendable () -> Void) {
        let lines = ["HTTP/1.1 \(status)"] + fields + ["Content-Length: \(length)", "Cache-Control: no-store", "Connection: close", "", ""]
        connection.send(content: Data(lines.joined(separator: "\r\n").utf8), completion: .contentProcessed { [self] error in
            if error == nil { then() } else { connection.cancel() }
        })
    }
}
