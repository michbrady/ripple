import Foundation

/// Something that can hand out the audio sectors of a disc: a real drive, or a fixture.
public protocol AudioDisc: Sendable {
    var toc: DiscTOC { get }
    /// `count` sectors from `start`, as 16-bit stereo 44.1 kHz little-endian PCM
    /// (2352 bytes per sector).
    func readSectors(start: Int, count: Int) throws -> Data
}

public enum DiscError: Error, Equatable {
    case unreadable(sector: Int)
    case outOfRange
}

/// A made-up disc of sine tones, one pitch per track, for tests, snapshots, and
/// machines without a drive.
public struct FixtureDisc: AudioDisc {
    public static let sectorBytes = 2352
    public static let framesPerSector = 588

    public let toc: DiscTOC
    /// Sectors that fail to read, to test retries and errors.
    public let badSectors: Set<Int>

    public init(trackSeconds: [Double] = [2, 3, 2], badSectors: Set<Int> = []) {
        var entries: [DiscTOC.Entry] = []
        var lba = 0
        for (index, seconds) in trackSeconds.enumerated() {
            entries.append(.init(number: index + 1, lba: lba))
            lba += Int(seconds * Double(DiscTOC.sectorsPerSecond))
        }
        self.toc = DiscTOC(entries: entries, leadOut: lba)
        self.badSectors = badSectors
    }

    public func readSectors(start: Int, count: Int) throws -> Data {
        guard start >= 0, count >= 0, start + count <= toc.leadOut else { throw DiscError.outOfRange }
        var samples = [Int16]()
        samples.reserveCapacity(count * Self.framesPerSector * 2)
        for sector in start..<(start + count) {
            if badSectors.contains(sector) { throw DiscError.unreadable(sector: sector) }
            let track = toc.entries.lastIndex { $0.lba <= sector } ?? 0
            let frequency = [440.0, 554.37, 659.25][track % 3]
            for frame in 0..<Self.framesPerSector {
                let n = Double(sector * Self.framesPerSector + frame)
                let value = Int16(sin(2 * .pi * frequency * n / 44_100) * 0.3 * 32_767)
                samples.append(value)
                samples.append(value)
            }
        }
        return samples.withUnsafeBytes { Data($0) }
    }
}
