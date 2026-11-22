#if DEBUG
import Foundation

/// Serves the PRDB wire format in process. The client still constructs requests, checks
/// status codes and decodes every response through its normal transport boundary.
package struct TestLibraryAPI: Sendable {
    package static let key = "vieweroo-fixture"
    private let manifest: URL

    package init(manifest: URL) { self.manifest = manifest }

    private struct Record: Decodable {
        let osHash: String
        let filesize: Int64
        let video: Video
    }

    private struct QueryFile: Decodable {
        let ref: String
        let osHash: String?
        let filesize: Int64
    }

    private struct Match: Encodable {
        let ref: String
        let videoId: String?
        let video: Video?
        let matchedBy: Int?
        let confidence: Int
        let candidates: [String] = []
    }

    private struct Page<Item: Encodable>: Encodable {
        let items: [Item]
        let totalCount: Int
    }

    package var client: PRDBClient { PRDBClient(transport: respond) }

    private func respond(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw PRDBError.invalidResponse }
        func reply<T: Encodable>(_ value: T, status: Int = 200) throws -> (Data, HTTPURLResponse) {
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            return (try JSONEncoder().encode(value), response)
        }
        guard request.value(forHTTPHeaderField: "X-Api-Key") == Self.key else {
            return try reply(["error": "Invalid fixture key"], status: 401)
        }
        if request.httpMethod == "GET", url.path == "/user-identity" {
            return try reply(["userHash": "vieweroo-test-library"])
        }

        let records = try JSONDecoder().decode([Record].self, from: Data(contentsOf: manifest))
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func parameter(_ name: String) -> String? { query.first { $0.name == name }?.value }
        let body = request.httpBody ?? Data()
        switch (request.httpMethod, url.path) {
        case ("GET", "/sites"):
            var seen = Set<String>()
            let term = parameter("Search") ?? ""
            let sites = records.compactMap(\.video.site).filter {
                seen.insert($0.id).inserted && (term.isEmpty || $0.title.localizedCaseInsensitiveContains(term))
            }
            let size = min(1000, max(1, Int(parameter("PageSize") ?? "") ?? 1000))
            let page = min(sites.count + 1, max(1, Int(parameter("Page") ?? "") ?? 1))
            return try reply(Page(items: Array(sites.dropFirst((page - 1) * size).prefix(size)), totalCount: sites.count))
        case ("POST", "/videos/identify"):
            struct Input: Decodable {
                let files: [QueryFile]
                let includeVideoDetails: Bool?
            }
            let input = try JSONDecoder().decode(Input.self, from: body)
            let matches = input.files.map { file in
                let hits = records.filter { $0.osHash == file.osHash && $0.filesize == file.filesize }
                guard hits.count == 1, let hit = hits.first else {
                    return Match(ref: file.ref, videoId: nil, video: nil, matchedBy: nil, confidence: 0)
                }
                return Match(ref: file.ref, videoId: hit.video.id, video: input.includeVideoDetails == true ? hit.video : nil,
                             matchedBy: 0, confidence: 4)
            }
            return try reply(["results": matches])
        case ("POST", "/videos/batch"):
            struct Batch: Decodable { let ids: [String] }
            let ids = Set(try JSONDecoder().decode(Batch.self, from: body).ids)
            return try reply(records.map(\.video).filter { ids.contains($0.id) })
        case ("GET", "/actors"):
            let term = parameter("Search") ?? ""
            var seen = Set<String>()
            let actors = records.flatMap(\.video.actors).filter {
                seen.insert($0.id).inserted && (term.isEmpty || $0.name.localizedCaseInsensitiveContains(term))
            }.sorted { $0.name < $1.name }
            return try reply(Page(items: Array(actors.prefix(50)), totalCount: actors.count))
        case ("GET", "/videos"):
            let term = parameter("Search") ?? ""
            let rows = records.compactMap { record -> Summary? in
                let video = record.video
                guard let site = video.site,
                      parameter("SiteId").map({ $0 == site.id }) ?? true,
                      parameter("ActorId").map({ id in video.actors.contains { $0.id == id } }) ?? true,
                      term.isEmpty || video.title.localizedCaseInsensitiveContains(term)
                          || site.title.localizedCaseInsensitiveContains(term) else { return nil }
                return Summary(platformId: site.platformId, platformKey: site.platformKey,
                               platformTitle: site.platformTitle, accountHandle: site.accountHandle, id: video.id, title: video.title, siteId: site.id, siteTitle: site.title, actors: video.actors)
            }
            let page = min(rows.count + 1, max(1, Int(parameter("Page") ?? "") ?? 1))
            let size = min(100, max(1, Int(parameter("PageSize") ?? "") ?? 20))
            return try reply(Page(items: Array(rows.dropFirst((page - 1) * size).prefix(size)), totalCount: rows.count))
        default:
            if request.httpMethod == "GET", let video = records.first(where: { url.path == "/videos/" + $0.video.id })?.video {
                return try reply(video)
            }
            return try reply(["error": "Unknown fixture resource"], status: 404)
        }
    }

    /// Only the generated fixture key and any test PIN verifier live in this suite.
    @MainActor package static func access(preferences: UserDefaults) -> AccessController {
        let store = FixtureSecrets(preferences: preferences)
        if !preferences.bool(forKey: "fixtureAccessInitialized") {
            store.write(Data(key.utf8), account: "PRDB API key")
            preferences.set(true, forKey: "fixtureAccessInitialized")
        }
        return AccessController(store: store)
    }
}

@MainActor
private struct FixtureSecrets: SecretStore {
    let preferences: UserDefaults
    func read(_ account: String) -> Data? { preferences.data(forKey: "fixture." + account) }
    func write(_ data: Data?, account: String) { preferences.set(data, forKey: "fixture." + account) }
}
#endif
