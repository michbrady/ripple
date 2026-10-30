import Foundation

/// Turns titles into safe file and folder names on macOS.
public enum FileNamer {
    /// A file name holds at most 255 UTF-8 bytes on APFS.
    public static let maxNameBytes = 255

    /// One path component: `/` and `:` become `-`, control characters go,
    /// leading dots and edge spaces trim, the text is normalized to NFC, and the
    /// result fits in `maxBytes` UTF-8 bytes without splitting a character.
    public static func clean(_ text: String, maxBytes: Int = 200, fallback: String = "Untitled") -> String {
        var result = ""
        for scalar in text.precomposedStringWithCanonicalMapping.unicodeScalars {
            if scalar == "/" || scalar == ":" {
                result.unicodeScalars.append("-")
            } else if scalar.properties.isWhitespace {
                result.unicodeScalars.append(" ")
            } else if CharacterSet.controlCharacters.contains(scalar) {
                continue
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        let words = result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var name = String(words.drop { $0 == "." })
            .trimmingCharacters(in: .whitespaces)
        while name.utf8.count > maxBytes { name.removeLast() }
        name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? fallback : name
    }

    /// `01 - Title.mp3`. The number gets three digits on discs with more than 99 tracks.
    /// With an `artist` (compilations), `01 - Artist - Title.mp3`.
    public static func trackFileName(number: Int, title: String, fileExtension: String,
                                     trackCount: Int = 0, artist: String? = nil) -> String {
        let width = max(trackCount, number) > 99 ? 3 : 2
        let prefix = String(format: "%0\(width)d - ", number)
        let suffix = "." + fileExtension
        let room = maxNameBytes - prefix.utf8.count - suffix.utf8.count - 8 // room for " (2)" and a temp prefix
        guard let artist, !artist.trimmingCharacters(in: .whitespaces).isEmpty else {
            return prefix + clean(title, maxBytes: room, fallback: "Track \(number)") + suffix
        }
        let who = clean(artist, maxBytes: room / 3, fallback: "Unknown Artist")
        let what = clean(title, maxBytes: room - who.utf8.count - 3, fallback: "Track \(number)")
        return prefix + who + " - " + what + suffix
    }

    /// Adds " (2)", " (3)" before the extension until the name is not in `taken`.
    public static func unique(_ name: String, taken: Set<String>) -> String {
        guard taken.contains(name) else { return name }
        let url = URL(fileURLWithPath: name)
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            if !taken.contains(candidate) { return candidate }
            n += 1
        }
    }
}
