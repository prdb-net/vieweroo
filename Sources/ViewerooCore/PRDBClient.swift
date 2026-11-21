import Foundation

public enum PRDBError: Error, LocalizedError, Equatable {
    case invalidKey
    case subscriptionRequired
    case rateLimited(retryAfter: TimeInterval?)
    case service(Int)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidKey: "PRDB rejected this API key. Enter a valid key to continue."
        case .subscriptionRequired: "This PRDB account needs a subscription that includes API access."
        case .rateLimited: "PRDB's request limit was reached. Try again later."
        case let .service(status): "PRDB returned HTTP \(status). Try again later."
        case .invalidResponse: "PRDB returned an unexpected response."
        }
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // X-Api-Key is a custom header and must never follow a redirect to another host.
        completionHandler(nil)
    }
}

public struct PRDBClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let transport: Transport
    private static let endpoint = URL(string: "https://api.prdb.net")!

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        self.init { request in
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw PRDBError.invalidResponse }
            return (data, response)
        }
    }

    init(transport: @escaping Transport) {
        self.transport = transport
    }

    public func validate(key: String) async throws {
        let identity: Identity = try await fetch("user-identity", key: key)
        guard !identity.userHash.isEmpty else { throw PRDBError.invalidResponse }
    }

    public func identify(_ files: [PRDBFile], key: String) async throws -> [String: PRDBMatch] {
        guard Set(files.map(\.ref)).count == files.count else { throw PRDBError.invalidResponse }
        var results: [String: PRDBMatch] = [:]
        for start in stride(from: 0, to: files.count, by: 200) {
            try Task.checkCancellation()
            let batch = Array(files[start..<min(files.count, start + 200)])
            let body = try JSONEncoder().encode(IdentifyRequest(files: batch))
            let response: Identification = try await fetch("videos/identify", key: key, body: body)
            guard response.results.count == batch.count,
                  Set(response.results.map(\.ref)) == Set(batch.map(\.ref)) else {
                throw PRDBError.invalidResponse
            }

            var videos: [String: PRDBTitle] = [:]
            var ids: Set<String> = []
            for row in response.results {
                if let video = row.video { videos[video.id] = video.titleRecord }
                if let id = row.videoId { ids.insert(id) }
                ids.formUnion(row.candidates)
            }
            let missing = ids.subtracting(videos.keys).sorted()
            for offset in stride(from: 0, to: missing.count, by: 50) {
                let ids = Array(missing[offset..<min(missing.count, offset + 50)])
                let body = try JSONEncoder().encode(["ids": ids])
                let details: [Video] = try await fetch("videos/batch", key: key, body: body)
                for detail in details { videos[detail.id] = detail.titleRecord }
            }

            let hashedRefs = Set(batch.filter { $0.osHash != nil }.map(\.ref))
            for row in response.results {
                let single = row.videoId.flatMap { videos[$0] }
                // The OpenAPI enums use integers. An ambiguous or unknown result never auto-links.
                let automatic = hashedRefs.contains(row.ref) && row.matchedBy == 0 &&
                    (1...4).contains(row.confidence) && row.candidates.isEmpty ? single : nil
                var candidates = row.candidates.compactMap { videos[$0] }
                if automatic == nil, let single, !candidates.contains(where: { $0.id == single.id }) {
                    candidates.insert(single, at: 0)
                }
                results[row.ref] = PRDBMatch(autoTitle: automatic, candidates: candidates, studio: row.site?.studio)
            }
        }
        return results
    }

    public func search(_ query: String, key: String) async throws -> [PRDBTitle] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        let response: Items<Summary> = try await fetch("videos", key: key, query: [
            URLQueryItem(name: "Search", value: term), URLQueryItem(name: "PageSize", value: "30")
        ])
        return response.items.map(\.titleRecord)
    }

    public func title(id: String, key: String) async throws -> PRDBTitle {
        guard UUID(uuidString: id) != nil else { throw PRDBError.invalidResponse }
        let detail: Video = try await fetch("videos/\(id)", key: key)
        return detail.titleRecord
    }

    public func studios(key: String) async throws -> [PRDBStudio] {
        var studios: [PRDBStudio] = []
        var page = 1
        while true {
            try Task.checkCancellation()
            let response: Page<Site> = try await fetch("sites", key: key, query: [
                URLQueryItem(name: "Page", value: String(page)), URLQueryItem(name: "PageSize", value: "1000")
            ])
            studios.append(contentsOf: response.items.map(\.studio))
            if studios.count >= response.totalCount || response.items.isEmpty { return studios }
            page += 1
        }
    }

    private func fetch<T: Decodable>(_ path: String, key: String, query: [URLQueryItem] = [],
                                     body: Data? = nil) async throws -> T {
        var url = Self.endpoint.appending(path: path)
        if !query.isEmpty { url.append(queryItems: query) }
        var request = URLRequest(url: url)
        request.setValue(key, forHTTPHeaderField: "X-Api-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, response) = try await transport(request)
        switch response.statusCode {
        case 200: return try JSONDecoder().decode(T.self, from: data)
        case 401: throw PRDBError.invalidKey
        case 403: throw PRDBError.subscriptionRequired
        case 429:
            let delay = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw PRDBError.rateLimited(retryAfter: delay)
        default: throw PRDBError.service(response.statusCode)
        }
    }
}

private struct Identity: Decodable { let userHash: String }
private struct Items<T: Decodable>: Decodable { let items: [T] }
private struct Page<T: Decodable>: Decodable {
    let items: [T]
    let totalCount: Int
}
private struct IdentifyRequest: Encodable {
    let files: [PRDBFile]
    let includeVideoDetails = true
}
private struct Identification: Decodable { let results: [ResultRow] }
private struct ResultRow: Decodable {
    let ref: String
    let confidence: Int
    let matchedBy: Int?
    let videoId: String?
    let video: Video?
    let site: Site?
    let candidates: [String]
}
struct Site: Codable {
    let id: String
    let title: String
    var studio: PRDBStudio { PRDBStudio(id: id, name: title) }
}
struct RemoteImage: Codable {
    let url: String?
    let imageType: Int?
    var httpsURL: URL? {
        guard let url, let parsed = URL(string: url), parsed.scheme?.lowercased() == "https",
              parsed.host != nil else { return nil }
        return parsed
    }
}
struct Performer: Codable {
    let id: String
    let name: String
    let images: [RemoteImage]?
    var record: PRDBPerformer {
        let images = images ?? []
        let face = images.first { $0.imageType == 3 && $0.httpsURL != nil }?.httpsURL
        return PRDBPerformer(id: id, name: name, portraitURL: face ?? images.lazy.compactMap(\.httpsURL).first)
    }
}
struct Video: Codable {
    let id: String
    let title: String
    let site: Site?
    let actors: [Performer]
    let images: [RemoteImage]
    var titleRecord: PRDBTitle {
        PRDBTitle(id: id, title: title, studio: site?.studio, performers: actors.map(\.record),
                  previewURL: images.lazy.compactMap(\.httpsURL).first)
    }
}
struct Summary: Codable {
    let id: String
    let title: String
    let siteId: String
    let siteTitle: String
    let actors: [Performer]
    var titleRecord: PRDBTitle {
        PRDBTitle(id: id, title: title, studio: PRDBStudio(id: siteId, name: siteTitle),
                  performers: actors.map(\.record))
    }
}
