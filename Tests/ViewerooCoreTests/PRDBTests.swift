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

    @Test func identifyMapsResultsByRefAndOnlyAutoLinksUniqueHashes() async throws {
        let film = #"{"id":"one","title":"River","site":{"id":"s","title":"Birch"},"actors":[{"id":"p","name":"Alex","images":[{"imageType":3,"url":"https://img.example/p.jpg"}]}],"images":[{"url":"https://img.example/v.jpg"}]}"#
        let other = #"{"id":"two","title":"Ridge","actors":[],"images":[]}"#
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
        #expect(results["two"]?.autoTitle == nil)
        #expect(results["two"]?.candidates == [auto])
        #expect(results["three"]?.autoTitle == nil)
        #expect(results["three"]?.studio?.name == "Birch")
        #expect(results["four"]?.autoTitle == nil)
        #expect(results["four"]?.candidates.map(\.id) == ["two", "one"])
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
            return reply(#"{"items":[{"id":"v","title":"Blue & Gold","siteId":"s","siteTitle":"Sky","actors":[{"id":"a","name":"Alex"}]}]}"#, request)
        }
        #expect(try await client.search(" Blue & Gold ", key: "key").first?.performers.first?.name == "Alex")
        #expect(try await client.studios(key: "key").map(\.name) == ["Sky", "Hill"])
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
