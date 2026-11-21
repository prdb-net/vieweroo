import Foundation

public struct StudioRecognition: Sendable {
    private let names: [String: Set<PRDBStudio>]
    private let longestName: Int

    public init(studios: [PRDBStudio]) {
        var names: [String: Set<PRDBStudio>] = [:]
        var longestName = 0
        for studio in studios {
            let name = Self.words(studio.name).joined()
            guard !name.isEmpty else { continue }
            longestName = max(name.count, longestName)
            names[name, default: []].insert(studio)
        }
        self.names = names
        self.longestName = longestName
    }

    public func match(url: URL) -> PRDBStudio? {
        guard longestName > 0 else { return nil }
        var matches: Set<PRDBStudio> = []
        for component in url.deletingPathExtension().pathComponents {
            let words = Self.words(component)
            for start in words.indices {
                var phrase = ""
                for word in words[start...] {
                    phrase += word
                    if phrase.count > longestName { break }
                    if let studios = names[phrase] {
                        matches.formUnion(studios)
                        if matches.count > 1 { return nil }
                    }
                }
            }
        }
        return matches.first
    }

    private static func words(_ value: String) -> [String] {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                      locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
