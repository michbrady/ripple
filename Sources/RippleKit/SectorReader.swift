import Foundation

/// What went wrong while reading a track.
public struct ReadIssues: Equatable, Sendable {
    /// Sectors that could not be read after every retry. They are filled with silence.
    public var unreadable: [Int] = []
    /// Sectors whose repeated reads never agreed, so the data may be wrong.
    public var suspect: [Int] = []
    /// How many extra reads it took.
    public var retries = 0

    public init() {}
    public var isClean: Bool { unreadable.isEmpty && suspect.isEmpty }
}

/// Reads sectors from a disc and copes with a scratched one: a failed read is tried again, and with
/// `verify` on every read is repeated until two reads agree, so a drive that returns wrong data without
/// an error is caught too. Sectors that never read cleanly become silence and are listed in `issues`.
///
/// Drives keep recent sectors in a cache, which would make a repeat read return the same wrong bytes.
/// Before each repeat the reader reads a sector far away, to push the cache out.
public struct SectorReader {
    public static let sectorBytes = 2_352
    /// About 4.6 MB away, more than a drive cache holds.
    static let cacheBustDistance = 2_000

    private let disc: any AudioDisc
    private let verify: Bool
    private let maxRetries: Int
    public private(set) var issues = ReadIssues()

    public init(disc: any AudioDisc, verify: Bool = true, maxRetries: Int = 3) {
        self.disc = disc
        self.verify = verify
        self.maxRetries = maxRetries
    }

    /// `count` sectors from `start`. Throws only when the range is outside the disc or the task is cancelled.
    public mutating func read(start: Int, count: Int) throws -> Data {
        guard let first = try attempt(start, count) else { return try readEach(start, count) }
        guard verify else { return first }
        bustCache(near: start)
        guard let second = try attempt(start, count) else { return try readEach(start, count) }
        if first == second { return first }
        // The reads disagree: settle it one sector at a time.
        var out = Data()
        for index in 0..<count {
            let range = index * Self.sectorBytes ..< (index + 1) * Self.sectorBytes
            let a = first[first.startIndex + range.lowerBound ..< first.startIndex + range.upperBound]
            let b = second[second.startIndex + range.lowerBound ..< second.startIndex + range.upperBound]
            out.append(a == b ? Data(b) : try confirm(start + index, previous: Data(b)))
        }
        return out
    }

    /// One read, tried again up to `maxRetries` times. Nil when every try failed.
    private mutating func attempt(_ start: Int, _ count: Int) throws -> Data? {
        for tryNumber in 0...maxRetries {
            if Task.isCancelled { throw CancellationError() }
            if tryNumber > 0 {
                issues.retries += 1
                bustCache(near: start)
            }
            do {
                return try disc.readSectors(start: start, count: count)
            } catch DiscError.outOfRange {
                throw DiscError.outOfRange
            } catch {
                continue
            }
        }
        return nil
    }

    private mutating func readEach(_ start: Int, _ count: Int) throws -> Data {
        var out = Data()
        for sector in start..<(start + count) {
            if let one = try attempt(sector, 1) {
                out.append(verify ? try confirm(sector, previous: one) : one)
            } else {
                issues.unreadable.append(sector)
                out.append(Data(count: Self.sectorBytes))
            }
        }
        return out
    }

    /// Reads one sector again until two reads in a row agree. If they never do, the last read is kept and the sector is marked suspect.
    private mutating func confirm(_ sector: Int, previous: Data) throws -> Data {
        var previous = previous
        for _ in 0...maxRetries {
            bustCache(near: sector)
            guard let next = try attempt(sector, 1) else { break }
            if next == previous { return next }
            previous = next
        }
        issues.suspect.append(sector)
        return previous
    }

    private func bustCache(near sector: Int) {
        let total = disc.toc.leadOut
        guard total > Self.cacheBustDistance else { return }
        let far = sector + Self.cacheBustDistance < total ? sector + Self.cacheBustDistance : sector - Self.cacheBustDistance
        _ = try? disc.readSectors(start: max(0, far), count: 1)
    }
}
