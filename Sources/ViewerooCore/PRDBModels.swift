import Foundation

public struct CreatorAccount: Codable, Hashable, Sendable {
    public let platformID: String?
    public let key: String?
    public let title: String?
    public let handle: String?

    init?(platformID: String?, key: String?, title: String?, handle: String?) {
        guard platformID != nil || key != nil else { return nil }
        self.platformID = platformID
        self.key = key?.lowercased()
        self.title = title
        var clean = handle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if clean.first == "@" { clean.removeFirst() }
        self.handle = clean.isEmpty ? nil : clean
    }

    public var platform: String { title ?? key ?? "Creator platform" }

    public var profileURL: URL? {
        guard let handle, (2...100).contains(handle.utf8.count),
              handle != "..", handle.utf8.allSatisfy({
                  (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0)
              }) else { return nil }
        switch key {
        case "onlyfans": return URL(string: "https://onlyfans.com/" + handle)
        case "fansly": return URL(string: "https://fansly.com/" + handle)
        default: return nil
        }
    }
}

public struct PRDBStudio: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let creator: CreatorAccount?
    public init(id: String, name: String, creator: CreatorAccount? = nil) {
        self.creator = creator
        self.id = id
        self.name = name
    }

    /// One of a library's own studios, as a candidate for folder and file name recognition.
    static func custom(_ name: String) -> PRDBStudio { PRDBStudio(id: "custom:" + name, name: name) }
    var isCustom: Bool { id.hasPrefix("custom:") }
}

public struct PRDBPerformer: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let portraitURL: URL?
    public init(id: String, name: String, portraitURL: URL? = nil) {
        self.id = id
        self.name = name
        self.portraitURL = portraitURL
    }
}

public struct PRDBTitle: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let studio: PRDBStudio?
    public let performers: [PRDBPerformer]
    public let previewURL: URL?
    public let alternativeTitle: String?
    public let durationSeconds: Int?
    /// Nil for a cached title from before API 0.27. An empty array is a known untagged title.
    public let tagKeys: [String]?
    public init(id: String, title: String, studio: PRDBStudio? = nil,
                performers: [PRDBPerformer] = [], previewURL: URL? = nil,
                alternativeTitle: String? = nil, durationSeconds: Int? = nil, tagKeys: [String]? = nil) {
        self.id = id
        self.title = title
        self.studio = studio
        self.performers = performers
        self.previewURL = previewURL
        self.alternativeTitle = alternativeTitle
        self.durationSeconds = durationSeconds
        self.tagKeys = tagKeys
    }
}

struct PRDBTag: Codable, Sendable {
    let key: String
    let name: String
}

public struct PRDBMatch: Codable, Hashable, Sendable {
    public let autoTitle: PRDBTitle?
    public let candidates: [PRDBTitle]
    public let studio: PRDBStudio?
    public init(autoTitle: PRDBTitle? = nil, candidates: [PRDBTitle] = [], studio: PRDBStudio? = nil) {
        self.autoTitle = autoTitle
        self.candidates = candidates
        self.studio = studio
    }
}

public struct PRDBFile: Encodable, Sendable {
    public let ref: String
    public let filename: String
    public let filesize: Int64
    public let osHash: String?
    public init(ref: String, filename: String, filesize: Int64, osHash: String?) {
        self.ref = ref
        self.filename = (filename as NSString).lastPathComponent
        self.filesize = filesize
        self.osHash = osHash
    }
}
