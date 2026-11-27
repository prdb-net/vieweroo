import Foundation
import Testing
@testable import ViewerooCore

struct PRDBTests {
    private func reply(_ json: String, _ request: URLRequest, status: Int = 200) -> (Data, HTTPURLResponse) {
        (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: status,
                                          httpVersion: nil, headerFields: nil)!)
    }

    @Test func invalidRetryDelayFallsBackToTheNormalRetryInterval() async {
        for value in ["inf", "NaN", "-5"] {
            let client = PRDBClient { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil,
                                               headerFields: ["Retry-After": value])!
                return (Data(), response)
            }
            await #expect(throws: PRDBError.rateLimited(retryAfter: nil)) {
                try await client.validate(key: "fixture")
            }
        }
    }

    @Test func manualAndBackgroundRequestsHonorTheSameKeySpecificRetryDeadline() async throws {
        actor Server {
            var paths: [String] = []
            func respond(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
                let url = try #require(request.url)
                paths.append(url.path)
                if url.path == "/user-identity" {
                    return (Data(#"{"userHash":"valid"}"#.utf8),
                            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }
                let delay = url.path == "/videos/identify" ? "Sun, 06 Nov 2095 08:49:37 GMT" : "120"
                return (Data(), HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil,
                                                headerFields: ["Retry-After": delay])!)
            }
        }
        let server = Server()
        let background = PRDBClient { try await server.respond($0) }
        let manual = background
        let files = [PRDBFile(ref: "1", filename: "video.mp4", filesize: 5, osHash: nil)]
        await #expect(throws: PRDBError.rateLimited(retryAfter: 120)) {
            try await manual.search("Morning", key: "first")
        }
        await #expect(throws: PRDBError.self) { try await background.identify(files, key: "first") }
        do {
            _ = try await background.identify(files, key: "second")
            Issue.record("Expected the identification service to return a rate limit")
        } catch let PRDBError.rateLimited(delay) {
            #expect((delay ?? 0) > 120)
        }
        await #expect(throws: PRDBError.self) { try await manual.search("Morning", key: "second") }
        try await manual.validate(key: "replacement")
        #expect(await server.paths == ["/videos", "/videos/identify", "/user-identity"])
    }

    @Test func identifyMapsResultsByRefAndOnlyAutoLinksUniqueHashes() async throws {
        let film = #"{"id":"one","title":"River","alternativeTitle":"Rapids","durationSeconds":75,"durationMs":84000,"tags":["water"],"site":{"id":"s","title":"Birch"},"actors":[{"id":"p","name":"Alex","images":[{"imageType":3,"url":"https://img.example/p.jpg"}]}],"images":[{"url":"https://img.example/v.jpg"}]}"#
        let other = #"{"id":"two","title":"Ridge","alternativeTitle":null,"durationSeconds":null,"tags":[],"actors":[],"images":[]}"#
        let client = PRDBClient { request in
            #expect(request.value(forHTTPHeaderField: "X-Api-Key") == "test-key")
            #expect(request.httpMethod == "POST")
            let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            switch request.url?.path {
            case "/videos/identify":
                let files = try #require(body["files"] as? [[String: Any]])
                #expect(files.count == 4)
                #expect(body["includeVideoDetails"] as? Bool == true)
                #expect(files[0]["filename"] as? String == "River.mp4")
                #expect(files[0]["filesize"] as? Int == 131072)
                #expect(files[0]["osHash"] as? String == "0000000000020000")
                #expect(Set(files[1].keys) == ["filename", "filesize", "ref"])
                return reply("""
                {"results":[
                  {"ref":"four","confidence":5,"matchedBy":0,"candidates":["two","one"]},
                  {"ref":"three","confidence":1,"matchedBy":4,"site":{"id":"s","title":"Birch"},"candidates":[]},
                  {"ref":"two","confidence":3,"matchedBy":2,"videoId":"one","video":\(film),"candidates":[]},
                  {"ref":"one","confidence":4,"matchedBy":0,"videoId":"one","video":\(film),"candidates":[]}
                ]}
                """, request)
            case "/videos/batch":
                #expect(body["ids"] as? [String] == ["two"])
                return reply("[\(other)]", request)
            default:
                throw PRDBError.invalidResponse
            }
        }
        let files = ["one", "two", "three", "four"].map {
            PRDBFile(ref: $0, filename: "/private/example/River.mp4", filesize: 131072,
                     osHash: $0 == "two" ? nil : "0000000000020000")
        }
        let results = try await client.identify(files, key: "test-key")
        let auto = try #require(results["one"]?.autoTitle)
        #expect(auto.performers.first?.portraitURL?.host == "img.example")
        #expect(auto.previewURL?.lastPathComponent == "v.jpg")
        #expect(auto.studio?.name == "Birch")
        #expect(auto.alternativeTitle == "Rapids")
        #expect(auto.durationSeconds == 75)
        #expect(auto.tagKeys == ["water"])
        #expect(results["two"]?.autoTitle == nil)
        #expect(results["two"]?.candidates == [auto])
        #expect(results["three"]?.autoTitle == nil)
        #expect(results["three"]?.studio?.name == "Birch")
        #expect(results["four"]?.autoTitle == nil)
        #expect(results["four"]?.candidates.map(\.id) == ["two", "one"])
        #expect(results["four"]?.candidates.first?.tagKeys == [])
        #expect(results["four"]?.candidates.first?.durationSeconds == nil)
    }

    @Test func identifySplitsRequestsAtTwoHundred() async throws {
        actor Counts {
            var batches: [Int] = []
            func append(_ count: Int) { batches.append(count) }
        }
        let counts = Counts()
        let client = PRDBClient { request in
            let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            let files = try #require(body["files"] as? [[String: Any]])
            await counts.append(files.count)
            let results = files.map { ["ref": $0["ref"]!, "confidence": 0, "candidates": []] as [String: Any] }
            return (try JSONSerialization.data(withJSONObject: ["results": results]),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let rows = (0..<401).map { PRDBFile(ref: String($0), filename: "Sample.mp4", filesize: 1, osHash: nil) }
        let results = try await client.identify(rows, key: "sample")
        #expect(results.count == 401)
        #expect(await counts.batches == [200, 200, 1])
    }

    @Test func incompleteResponsesLeaveLookupsPending() async throws {
        let client = PRDBClient { reply(#"{"results":[]}"#, $0) }
        await #expect(throws: PRDBError.invalidResponse) {
            try await client.identify([.init(ref: "1", filename: "sample.mov", filesize: 3, osHash: nil)], key: "test")
        }
    }

    @Test func searchAndStudioPagesUsePublicContract() async throws {
        let client = PRDBClient { request in
            let url = try #require(request.url)
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if url.path == "/sites" {
                let second = query.contains(.init(name: "Page", value: "2"))
                let name = second ? "Hill" : "Sky"
                return reply("""
                {"totalCount":2,"items":[{"id":"\(name)","title":"\(name)"}]}
                """, request)
            }
            #expect(url.path == "/videos")
            #expect(query.contains(.init(name: "Search", value: "Blue & Gold")))
            return reply(#"{"totalCount":1,"items":[{"id":"v","title":"Blue & Gold","siteId":"s","siteTitle":"Sky","actors":[{"id":"a","name":"Alex"}]}]}"#, request)
        }
        #expect(try await client.search(" Blue & Gold ", key: "key").first?.performers.first?.name == "Alex")
        #expect(try await client.studios(key: "key").map(\.name) == ["Sky", "Hill"])
    }

    @Test func releaseStudioMustStartAtTheFirstCharacterAndEndAtASeparator() {
        let compound = PRDBStudio(id: "c", name: "CedarGrove")
        let plain = PRDBStudio(id: "a", name: "Arcadia")
        let black = PRDBStudio(id: "b", name: "Black")
        let longer = PRDBStudio(id: "l", name: "Black Lantern")
        let videos = PRDBStudio(id: "v", name: "HomeVideo")
        let recognition = StudioRecognition(studios: [compound, plain, black, longer, videos])
        func find(_ filename: String) -> PRDBStudio? {
            recognition.match(url: URL(fileURLWithPath: "/Library/" + filename), sourcePath: "/Library")
        }
        for separator in [".", "-", "_", " "] {
            #expect(find("cedargrove" + separator + "River.mp4") == compound)
        }
        #expect(find("Cédar.Grove.24.03.01.River.XXX.1080p.MP4-GRP.mp4") == compound)
        #expect(find("BlackLantern-River.mp4") == longer)
        #expect(find("Arcadia_2024-02-29_River.mp4") == plain)
        #expect(find("Arcadia.24.12.31.River.mp4") == plain)
        for filename in ["River.CedarGrove.24.03.01.mp4", "CedarGrovehouse.River.mp4",
                         "-CedarGrove.River.mp4", "[CedarGrove].River.mp4", "CedarGrove+River.mp4",
                         "Arcadia.River.mp4", "Arcadia.23.02.29.River.mp4", "Black.River.mp4",
                         "Black.24.03.01.River.mp4", "River.Black.24.03.01.mp4",
                         "Black/River.mp4", "HomeVideo.24.03.01.River.mp4", "My CedarGrove Collection/River.mp4"] {
            #expect(find(filename) == nil)
        }
        #expect(find("Arcadia/River.mp4") == plain)
        #expect(recognition.match(url: URL(fileURLWithPath: "/Arcadia/Library/River.mp4"),
                                  sourcePath: "/Arcadia/Library") == nil)
        let collision = StudioRecognition(studios: [compound, PRDBStudio(id: "other", name: "Cedar Grove")])
        #expect(collision.match(url: URL(fileURLWithPath: "/library/CedarGrove-River.mp4")) == nil)
    }

    @Test func studioRecognitionLeavesConflictingNamesUnresolved() {
        let grove = PRDBStudio(id: "1", name: "Cedar Grove")
        let lake = PRDBStudio(id: "2", name: "Silver Lake")
        let recognizer = StudioRecognition(studios: [grove, lake])
        func find(_ path: String) -> PRDBStudio? { recognizer.match(url: URL(fileURLWithPath: path)) }
        #expect(find("/catalog/cedar.grove/River.mov") == grove)
        #expect(find("/catalog/cedargrove/CEDAR-GROVE-River.MP4") == grove)
        #expect(find("/catalog/ridge/silver.lake-dawn.mov") == lake)
        #expect(find("/catalog/cedar grove/silver.lake-dawn.mov") == nil)
        #expect(find("/catalog/cedargroves/other.mov") == nil)
    }
}
