import Foundation

public struct StudioRecognition: Sendable {
    // Common title words and release metadata provide no publisher evidence on their own.
    private static let generic: Set<String> = [
        "black", "white", "red", "green", "blue", "pink", "blonde", "brunette",
        "amateur", "adult", "babes", "classic", "compilation", "exclusive", "hardcore",
        "home", "hot", "love", "new", "porn", "private", "raw", "real", "sex", "solo", "teen",
        "collection", "clips", "downloads", "film", "films", "media", "movie", "movies",
        "scene", "scenes", "studio", "studios", "video", "videos", "hd", "full", "fullhd",
        "4k", "uhd", "1080p", "2160p", "mp4", "web", "xxx"
    ]
    private static let separators = CharacterSet(charactersIn: ".-_").union(.whitespaces)
    private var names: [String: Set<PRDBStudio>] = [:]
    private var compounds: Set<String> = []
    private var longestName = 0

    public init(studios: [PRDBStudio]) {
        for studio in studios { add(studio) }
    }

    mutating func add(_ studio: PRDBStudio) {
        // Use the directory spelling to distinguish a compound brand from a plain word.
        var expanded = ""
        for letter in studio.name {
            if letter.isUppercase && expanded.last?.isLowercase == true { expanded.append(" ") }
            expanded.append(letter)
        }
        let words = Self.parts(expanded)
        let key = words.joined()
        guard key.count >= 3, key.contains(where: \.isLetter),
              !Self.generic.contains(key), !words.allSatisfy(Self.generic.contains) else { return }
        // A library's own studio must not make a directory studio of the same spelling
        // ambiguous. The directory is added first and keeps the name.
        if studio.isCustom, names[key]?.contains(where: { !$0.isCustom }) == true { return }
        names[key, default: []].insert(studio)
        longestName = max(longestName, key.count)
        if words.count > 1 { compounds.insert(key) }
    }

    public func match(url: URL, sourcePath: String? = "/", siteHint: PRDBStudio? = nil) -> PRDBStudio? {
        var matches = candidates(url: url, sourcePath: sourcePath)
        if let siteHint, names[Self.parts(siteHint.name).joined()]?.contains(where: { $0.id == siteHint.id }) != true {
            let hint = StudioRecognition(studios: [siteHint])
            matches.formUnion(hint.candidates(url: url, sourcePath: sourcePath))
        }
        return matches.count == 1 ? matches.first : nil
    }

    private func candidates(url: URL, sourcePath: String?) -> Set<PRDBStudio> {
        guard longestName > 0 else { return [] }
        var matches: Set<PRDBStudio> = []
        if let sourcePath {
            let source = URL(fileURLWithPath: sourcePath, isDirectory: true).pathComponents
            let folders = url.deletingLastPathComponent().pathComponents
            if folders.starts(with: source) {
                for folder in folders.dropFirst(max(0, source.count - 1)) {
                    let key = Self.parts(folder).joined()
                    if let studios = names[key] { matches.formUnion(studios) }
                }
            }
        }

        let stem = url.deletingPathExtension().lastPathComponent
        if let first = stem.unicodeScalars.first, CharacterSet.alphanumerics.contains(first) {
            let parts = Self.parts(stem)
            var prefix = ""
            for index in parts.indices.dropLast() {
                prefix += parts[index]
                if prefix.count > longestName { break }
                guard let studios = names[prefix] else { continue }
                if compounds.contains(prefix) || Self.startsWithDate(parts[(index + 1)...]) {
                    matches.formUnion(studios)
                }
            }
        }
        return matches
    }

    private static func parts(_ value: String) -> [String] {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                      locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: separators)
            .filter { !$0.isEmpty }
    }

    // Scene releases commonly start with Publisher.YY.MM.DD or Publisher.YYYY.MM.DD.
    private static func startsWithDate(_ suffix: ArraySlice<String>) -> Bool {
        guard suffix.count > 3 else { return false }
        let index = suffix.startIndex
        let year = suffix[index], month = suffix[index + 1], day = suffix[index + 2]
        guard [2, 4].contains(year.count), month.count == 2, day.count == 2,
              [year, month, day].allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) } }),
              let y = Int(year), let m = Int(month), let d = Int(day), (1...12).contains(m) else { return false }
        let fullYear = year.count == 2 ? 2000 + y : y
        let leap = fullYear.isMultiple(of: 4) && (!fullYear.isMultiple(of: 100) || fullYear.isMultiple(of: 400))
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return (1900...2099).contains(fullYear) && (1...days[m - 1]).contains(d)
    }
}
