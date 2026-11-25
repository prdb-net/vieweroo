import Foundation

/// Turn a release-style file name into words a title search can match. A stem such as
/// `Studio.24.01.05.Some.Title.XXX.1080p.MP4-GRP` contains separators, a date and encoding
/// labels that never occur in a PRDB title.
public enum SearchTerm {
    /// Encoding and container labels, which no title contains.
    private static let labels: Set<String> = [
        "xxx", "fhd", "uhd", "4k", "10bit", "8bit",
        "h264", "h265", "x264", "x265", "hevc", "avc", "av1", "vp9", "aac", "ac3",
        "webrip", "webdl", "hdrip", "bluray", "bdrip", "dvdrip", "hdtv",
        "mp4", "m4v", "mov", "mkv", "avi", "wmv"
    ]
    /// Labels that are also ordinary words. They are dropped only from a release-style
    /// name, which has no spaces, so "The Proper Way" keeps its words.
    private static let releaseWords: Set<String> = [
        "hd", "sd", "hq", "8k", "hdr", "sdr", "mp3", "web", "repack", "proper", "internal"
    ]

    public static func clean(_ stem: String, studio: String? = nil) -> String {
        var text = stem
        for bracket in "[](){}" { text = text.replacingOccurrences(of: String(bracket), with: " ") }
        // Dots and underscores separate words in release names. A hyphen does so only in a
        // name without spaces, where it usually introduces the release group.
        let spaced = text.contains(" ")
        text = text.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: ".", with: " ")
        if !spaced { text = text.replacingOccurrences(of: "-", with: " ") }
        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)

        func isLabel(_ word: String) -> Bool {
            let lower = word.lowercased()
            if labels.contains(lower) || (!spaced && releaseWords.contains(lower)) { return true }
            // 720p, 1080p, 2160p, 60fps and similar encoding labels.
            for suffix in ["p", "fps", "kbps"] where lower.hasSuffix(suffix) {
                let number = lower.dropLast(suffix.count)
                if number.count >= 2, number.allSatisfy(\.isNumber) { return true }
            }
            return false
        }
        // A release name ends in its group after a hyphen, as in "….1080p.MP4-GRP". Take the
        // last word for the group only when it follows a label, so "Some-Title" keeps both words.
        if !spaced, let group = stem.split(separator: "-").last, stem.contains("-"),
           !group.contains("."), !group.contains("_"), words.count >= 2, words.last == String(group),
           isLabel(words[words.count - 2]) {
            words.removeLast()
        }
        words.removeAll(where: isLabel)
        if let index = dateStart(in: words) { words.removeSubrange(index..<(index + 3)) }
        words.removeAll(where: isCompactDate)
        if let studio { removePrefix(studio, from: &words) }

        let term = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: "-– ").union(.whitespaces))
        return term.isEmpty ? stem : term
    }

    private static func digits(_ word: String, _ lengths: [Int]) -> Int? {
        guard lengths.contains(word.count), word.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return Int(word)
    }

    /// The position of a YY MM DD or YYYY MM DD run.
    private static func dateStart(in words: [String]) -> Int? {
        guard words.count >= 3 else { return nil }
        return (0...(words.count - 3)).first { index in
            guard let year = digits(words[index], [2, 4]), let month = digits(words[index + 1], [2]),
                  let day = digits(words[index + 2], [2]) else { return false }
            let full = words[index].count == 2 ? 2000 + year : year
            return (1900...2099).contains(full) && (1...12).contains(month) && (1...31).contains(day)
        }
    }

    /// 2024-01-05 or 20240105.
    private static func isCompactDate(_ word: String) -> Bool {
        let plain = word.replacingOccurrences(of: "-", with: "")
        guard plain.count == 8, let value = digits(plain, [8]) else { return false }
        return (1900...2099).contains(value / 10_000) && (1...12).contains(value / 100 % 100) && (1...31).contains(value % 100)
    }

    private static func letters(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// A release name starts with its studio, which a PRDB title does not repeat.
    private static func removePrefix(_ studio: String, from words: inout [String]) {
        let target = letters(studio)
        guard !target.isEmpty else { return }
        var joined = ""
        for (index, word) in words.enumerated() {
            joined += letters(word)
            if joined == target, index + 1 < words.count {
                words.removeSubrange(0...index)
                return
            }
            if !target.hasPrefix(joined) { return }
        }
    }
}
