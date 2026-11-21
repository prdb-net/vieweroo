import Foundation

public struct PRDBStudio: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
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
    public init(id: String, title: String, studio: PRDBStudio? = nil,
                performers: [PRDBPerformer] = [], previewURL: URL? = nil) {
        self.id = id
        self.title = title
        self.studio = studio
        self.performers = performers
        self.previewURL = previewURL
    }
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
