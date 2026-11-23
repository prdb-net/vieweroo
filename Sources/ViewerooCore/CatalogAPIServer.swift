import Foundation
import Network

/// One authenticated HTTP request per connection. Listener and client state share one
/// serial queue so stop() also revokes requests already being received. Catalog work runs
/// on its own queue, so stop() never waits for a database write to finish.
package final class CatalogAPIServer: @unchecked Sendable {
    package static let defaultPort: UInt16 = 47832
    typealias Responder = @Sendable (_ method: String, _ target: String, _ body: Data) -> CatalogResponse
    private let queue = DispatchQueue(label: "net.prdb.vieweroo.catalog-api", qos: .utility)
    private let work = DispatchQueue(label: "net.prdb.vieweroo.catalog-api.work", qos: .utility)
    private let listener: NWListener
    private let key: String
    private let respond: Responder
    private var clients: [ObjectIdentifier: NWConnection] = [:]
    private var stopped = false

    package convenience init(catalog: Catalog, key: String, port: UInt16 = defaultPort) throws {
        let api = CatalogAPI(catalog: catalog)
        try self.init(key: key, port: port) { api.respond(method: $0, target: $1, body: $2) }
    }

    init(key: String, port: UInt16, respond: @escaping Responder) throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        listener = try NWListener(using: parameters)
        self.key = key
        self.respond = respond
    }

    package func start(state: @escaping @Sendable (Result<UInt16, Error>) -> Void,
                       changed: @escaping @Sendable (Int64) -> Void) {
        listener.stateUpdateHandler = { [weak self] status in
            guard let self, !stopped else { return }
            switch status {
            case .ready: if let port = listener.port { state(.success(port.rawValue)) }
            case .failed(let error), .waiting(let error): state(.failure(error))
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, !stopped, clients.count < 8 else { connection.cancel(); return }
            let id = ObjectIdentifier(connection)
            clients[id] = connection
            let request = CatalogRequest(connection)
            connection.stateUpdateHandler = { [weak self] status in
                guard let self else {
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    return
                }
                switch status {
                case .ready:
                    receive(request, changed: changed)
                case .failed, .cancelled:
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    clients[id] = nil
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 30) { [weak connection] in connection?.cancel() }
        }
        listener.start(queue: queue)
    }

    package func stop() {
        queue.sync {
            stopped = true
            listener.cancel()
            for client in clients.values { client.forceCancel() }
            clients.removeAll()
        }
    }

    private func receive(_ request: CatalogRequest, changed: @escaping @Sendable (Int64) -> Void) {
        guard !stopped else { return }
        request.connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] bytes, _, eof, error in
            guard let self, !stopped, error == nil else { request.connection.cancel(); return }
            if let bytes { request.buffer.append(bytes) }
            if request.method == nil {
                if let end = request.buffer.range(of: Data("\r\n\r\n".utf8)) {
                    guard end.upperBound <= 16384,
                          let header = String(data: request.buffer[..<end.lowerBound], encoding: .utf8) else {
                        request.reject("400 Bad Request"); return
                    }
                    guard request.parse(header, key: key) else { return }
                    request.buffer = Data(request.buffer[end.upperBound...])
                } else if request.buffer.count >= 16384 { request.reject("431 Request Header Fields Too Large"); return }
            }
            if let method = request.method, request.buffer.count >= request.length {
                guard request.buffer.count == request.length else { request.reject("400 Bad Request"); return }
                let target = request.target, body = request.buffer
                work.async { [weak self] in
                    guard let self else { return }
                    let response = respond(method, target, body)
                    queue.async { [weak self] in
                        // A completed edit is committed even when the server stopped meanwhile.
                        if let library = response.changedLibrary { changed(library) }
                        guard let self, !stopped else { return }
                        request.send(response)
                    }
                }
            } else if eof { request.reject("400 Bad Request") }
            else { receive(request, changed: changed) }
        }
    }
}

private final class CatalogRequest: @unchecked Sendable {
    let connection: NWConnection
    var buffer = Data()
    var method: String?
    var target = ""
    var length = 0

    init(_ connection: NWConnection) { self.connection = connection }

    func parse(_ header: String, key: String) -> Bool {
        let lines = header.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        guard parts.count == 3, ["HTTP/1.0", "HTTP/1.1"].contains(parts[2]) else { return reject("400 Bad Request") }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, !pair[0].isEmpty, !pair[0].contains(where: \.isWhitespace) else { return reject("400 Bad Request") }
            let name = pair[0].lowercased()
            guard fields[name] == nil else { return reject("400 Bad Request") }
            fields[name] = pair[1].trimmingCharacters(in: .whitespaces)
        }
        guard fields["authorization"] == "Bearer " + key else { return reject("401 Unauthorized") }
        guard fields["transfer-encoding"] == nil else { return reject("400 Bad Request") }
        guard let count = Int(fields["content-length"] ?? "0"), count >= 0 else { return reject("400 Bad Request") }
        guard count <= 7 * 1024 * 1024 else { return reject("413 Content Too Large") }
        switch parts[0] {
        case "PATCH", "POST":
            guard fields["content-type"]?.components(separatedBy: ";").first?.lowercased() == "application/json" else {
                return reject("415 Unsupported Media Type")
            }
            guard count > 0 else { return reject("400 Bad Request") }
        case "GET":
            guard count == 0 else { return reject("400 Bad Request") }
        default: return reject("405 Method Not Allowed")
        }
        if let expect = fields["expect"] {
            guard expect.lowercased() == "100-continue" else { return reject("417 Expectation Failed") }
            connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .idempotent)
        }
        method = String(parts[0])
        target = String(parts[1])
        length = count
        return true
    }

    @discardableResult
    func reject(_ status: String) -> Bool {
        send(.init(error: status, message: status))
        return false
    }

    func send(_ response: CatalogResponse) {
        let head = ["HTTP/1.1 " + response.status, "Content-Type: application/json", "Content-Length: \(response.data.count)",
                    "Connection: close", "Cache-Control: no-store", "", ""].joined(separator: "\r\n")
        connection.send(content: Data(head.utf8) + response.data, completion: .contentProcessed { [connection] _ in connection.cancel() })
    }
}
