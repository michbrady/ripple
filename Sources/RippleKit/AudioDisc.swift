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
/// machines without a drive. It can also fail the ways a scratched disc does.
public struct FixtureDisc: AudioDisc {
    public static let sectorBytes = 2352
    public static let framesPerSector = 588

    /// Ways to make reads go wrong. Counters live in a shared box, so every copy of the disc sees them.
    public final class Faults: @unchecked Sendable {
        private let lock = NSLock()
        private var failures: [Int: Int]
        private var corruptions: [Int: Int]
        /// Sectors that always fail.
        public let permanent: Set<Int>
        public private(set) var reads = 0

        /// - failFirst: sector -> how many reads fail before one succeeds.
        /// - corruptFirst: sector -> how many reads return wrong bytes (with no error) before the right ones.
        public init(permanent: Set<Int> = [], failFirst: [Int: Int] = [:], corruptFirst: [Int: Int] = [:]) {
            self.permanent = permanent
            self.failures = failFirst
            self.corruptions = corruptFirst
        }

        /// Throws for a failing read; otherwise 0 for good data, or a nonzero token that changes every wrong read.
        func check(_ sector: Int) throws -> Int {
            lock.lock(); defer { lock.unlock() }
            if permanent.contains(sector) { throw DiscError.unreadable(sector: sector) }
            if let left = failures[sector], left > 0 {
                failures[sector] = left - 1
                throw DiscError.unreadable(sector: sector)
            }
            if let left = corruptions[sector], left > 0 {
                corruptions[sector] = left - 1
                return left
            }
            return 0
        }

        func countRead() { lock.lock(); reads += 1; lock.unlock() }
    }

    public let toc: DiscTOC
    public let faults: Faults

    public init(trackSeconds: [Double] = [2, 3, 2], badSectors: Set<Int> = [], faults: Faults? = nil) {
        var entries: [DiscTOC.Entry] = []
        var lba = 0
        for (index, seconds) in trackSeconds.enumerated() {
            entries.append(.init(number: index + 1, lba: lba))
            lba += Int(seconds * Double(DiscTOC.sectorsPerSecond))
        }
        self.toc = DiscTOC(entries: entries, leadOut: lba)
        self.faults = faults ?? Faults(permanent: badSectors)
    }

    public var badSectors: Set<Int> { faults.permanent }

    public func readSectors(start: Int, count: Int) throws -> Data {
        guard start >= 0, count >= 0, start + count <= toc.leadOut else { throw DiscError.outOfRange }
        faults.countRead()
        var samples = [Int16]()
        samples.reserveCapacity(count * Self.framesPerSector * 2)
        for sector in start..<(start + count) {
            let corruption = try faults.check(sector)
            let track = toc.entries.lastIndex { $0.lba <= sector } ?? 0
            let frequency = [440.0, 554.37, 659.25][track % 3]
            for frame in 0..<Self.framesPerSector {
                let n = Double(sector * Self.framesPerSector + frame)
                var value = Int16(sin(2 * .pi * frequency * n / 44_100) * 0.3 * 32_767)
                if corruption != 0 && frame % 7 == 0 { value = value &+ Int16(1_000 + corruption) }
                samples.append(value)
                samples.append(value)
            }
        }
        return samples.withUnsafeBytes { Data($0) }
    }
}
