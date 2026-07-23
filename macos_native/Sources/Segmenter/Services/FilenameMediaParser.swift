import Foundation

public final class FilenameMediaParser {
    private static let tvPattern = try! NSRegularExpression(
        pattern: #"(?i)(?:s|season\s*)(\d{1,2})[\s._-]*[ex](\d{1,3})|(\d{1,2})x(\d{1,3})"#
    )

    private static let yearPattern = try! NSRegularExpression(
        pattern: #"\b(19\d{2}|20\d{2})\b"#
    )

    private static let junkPattern = try! NSRegularExpression(
        pattern: #"(?i)\b(1080p|720p|4k|2160p|bluray|webrip|web-dl|h264|h265|hevc|x264|x265|aac|dts|flac|mkv|mp4|avi)\b"#
    )

    public static func parse(filePathOrName: String) -> ParsedFilenameHint {
        let fileName = (filePathOrName as NSString).lastPathComponent
        let baseName = (fileName as NSString).deletingPathExtension

        var season: Int? = nil
        var episode: Int? = nil
        var year: Int? = nil
        var cleanTitle = baseName

        // Search TV episode pattern
        let range = NSRange(location: 0, length: baseName.utf16.count)
        if let match = tvPattern.firstMatch(in: baseName, options: [], range: range) {
            if match.range(at: 1).location != NSNotFound, match.range(at: 2).location != NSNotFound {
                let sStr = (baseName as NSString).substring(with: match.range(at: 1))
                let eStr = (baseName as NSString).substring(with: match.range(at: 2))
                season = Int(sStr)
                episode = Int(eStr)
            } else if match.range(at: 3).location != NSNotFound, match.range(at: 4).location != NSNotFound {
                let sStr = (baseName as NSString).substring(with: match.range(at: 3))
                let eStr = (baseName as NSString).substring(with: match.range(at: 4))
                season = Int(sStr)
                episode = Int(eStr)
            }

            // Cut title at season match start
            cleanTitle = (baseName as NSString).substring(to: match.range.location)
        }

        // Search year pattern
        let titleRange = NSRange(location: 0, length: cleanTitle.utf16.count)
        if let yearMatch = yearPattern.firstMatch(in: cleanTitle, options: [], range: titleRange) {
            let yearStr = (cleanTitle as NSString).substring(with: yearMatch.range(at: 1))
            year = Int(yearStr)
            cleanTitle = (cleanTitle as NSString).substring(to: yearMatch.range.location)
        }

        // Strip release group junk and dots/underscores
        let junkRange = NSRange(location: 0, length: cleanTitle.utf16.count)
        cleanTitle = junkPattern.stringByReplacingMatches(in: cleanTitle, options: [], range: junkRange, withTemplate: "")
        cleanTitle = cleanTitle.replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return ParsedFilenameHint(
            title: cleanTitle,
            year: year,
            season: season,
            episode: episode
        )
    }
}
