import Foundation

/// File names on an MP3 Disc. A player that plays files by name follows the numbers, so the list order is
/// written into every name: `01 - Title.mp3`.
public enum BurnNaming {
    /// `position` is 1-based. A number the file already starts with ("07 - ", "7. ", "07_") is replaced,
    /// not doubled. `fileExtension` replaces the original one (an M4A burned as MP3). A title that merely begins with a number ("99 Luftballons", "1979") is kept whole.
    public static func discFileName(position: Int, of total: Int = 0, original: URL, maxStemBytes: Int = 48, fileExtension: String? = nil) -> String {
        let ext = fileExtension ?? original.pathExtension
        let fullStem = original.deletingPathExtension().lastPathComponent
        let stripped = stripLeadingNumber(fullStem)
        let stem = FileNamer.clean(stripped.isEmpty ? fullStem : stripped, maxBytes: maxStemBytes)
        let width = max(total, position) > 99 ? 3 : 2
        return String(format: "%0\(width)d - ", position) + stem + (ext.isEmpty ? "" : "." + ext)
    }

    /// "01 - One" -> "One", "7. Seven" -> "Seven", "03_Three" -> "Three". "99 Luftballons" stays as it is.
    static func stripLeadingNumber(_ stem: String) -> String {
        guard let range = stem.range(of: #"^\d{1,3}(\s*[-.)]\s+|_+)"#, options: .regularExpression) else { return stem }
        return String(stem[range.upperBound...])
    }
}
