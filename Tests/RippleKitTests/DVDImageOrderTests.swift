import CryptoKit
import Foundation
import Testing
@testable import RippleKit

@Suite struct DVDImageOrderTests {
    @Test func theOrderPutsEachIFOFirstAndEachBUPLastWithTheVOBsBetweenInNumber() {
        let shuffled = ["VTS_01_0.BUP", "VTS_02_1.VOB", "VIDEO_TS.BUP", "VTS_01_2.VOB", "VTS_01_0.IFO", "VIDEO_TS.VOB", "VTS_01_1.VOB",
                        "VIDEO_TS.IFO", "VTS_02_0.IFO", "VTS_01_0.VOB", "VTS_02_0.BUP"]
        #expect(DVDImageOrder.order(shuffled) == ["VIDEO_TS.IFO", "VIDEO_TS.VOB", "VIDEO_TS.BUP",
                                                  "VTS_01_0.IFO", "VTS_01_0.VOB", "VTS_01_1.VOB", "VTS_01_2.VOB", "VTS_01_0.BUP",
                                                  "VTS_02_0.IFO", "VTS_02_1.VOB", "VTS_02_0.BUP"])
    }

    @Test func versionSuffixesFromISO9660AreIgnored() {
        #expect(DVDImageOrder.order(["VTS_01_0.BUP;1", "VIDEO_TS.IFO;1", "VTS_01_1.VOB;1"]) == ["VIDEO_TS.IFO;1", "VTS_01_1.VOB;1", "VTS_01_0.BUP;1"])
    }

    @Test func crcMatchesTheKnownCheckValue() {
        // CRC-16/XMODEM ("123456789" is 0x31C3), the CRC UDF uses.
        #expect(DVDImageOrder.crc16(Array("123456789".utf8)[...]) == 0x31C3)
    }

    private func run(_ path: String, _ args: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func sha(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    /// A real hybrid image of a made-up disc, reordered, then mounted and compared file by file with the originals.
    @Test func aRealImageIsReorderedAndEveryFileStillReadsBackIdentically() throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appending(path: "ripple-order-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: work) }
        let video = work.appending(path: "disc/VIDEO_TS")
        try fm.createDirectory(at: video, withIntermediateDirectories: true)
        try fm.createDirectory(at: work.appending(path: "disc/AUDIO_TS"), withIntermediateDirectories: true)
        let sizes: [String: Int] = ["VIDEO_TS.IFO": 6, "VIDEO_TS.VOB": 230, "VIDEO_TS.BUP": 6, "VTS_01_0.IFO": 6, "VTS_01_0.VOB": 40,
                                    "VTS_01_1.VOB": 700, "VTS_01_2.VOB": 90, "VTS_01_0.BUP": 6]
        var seed: UInt8 = 1
        for (name, sectors) in sizes {
            seed &+= 37
            var bytes = (0..<(sectors * 2_048)).map { UInt8(truncatingIfNeeded: $0 &* Int(seed) &+ Int(seed)) }
            func put(_ value: Int, at index: Int) { for shift in 0..<4 { bytes[index + shift] = UInt8((value >> (8 * (3 - shift))) & 0xFF) } }
            // Real addresses, as dvdauthor writes them: counted in sectors from the start of the .IFO.
            if name == "VIDEO_TS.IFO" { put(sizes["VIDEO_TS.IFO"]! + sizes["VIDEO_TS.VOB"]! + sizes["VIDEO_TS.BUP"]! - 1, at: 0x0C); put(sizes["VIDEO_TS.IFO"]!, at: 0xC0) }
            if name == "VTS_01_0.IFO" {
                let ifo = sizes["VTS_01_0.IFO"]!, menu = sizes["VTS_01_0.VOB"]!, video = sizes["VTS_01_1.VOB"]! + sizes["VTS_01_2.VOB"]!
                put(ifo + menu + video + sizes["VTS_01_0.BUP"]! - 1, at: 0x0C); put(ifo, at: 0xC0); put(ifo + menu, at: 0xC4)
            }
            try Data(bytes).write(to: video.appending(path: name))
        }
        let image = work.appending(path: "disc.iso")
        #expect(try run("/usr/bin/hdiutil", ["makehybrid", "-udf", "-udf-version", "1.02", "-iso", "-iso-volume-name", "TEST", "-udf-volume-name", "TEST",
                                            "-default-volume-name", "TEST", "-o", image.path, work.appending(path: "disc").path]) == 0)

        let before = try DVDImageOrder.listing(of: image)
        let expected: Set<String> = ["VIDEO_TS.IFO", "VIDEO_TS.VOB", "VIDEO_TS.BUP", "VTS_01_0.IFO", "VTS_01_0.VOB", "VTS_01_1.VOB", "VTS_01_2.VOB", "VTS_01_0.BUP"]
        #expect(Set(before.map { String($0.name.split(separator: ";")[0]) }) == expected)
        #expect(try !DVDImageOrder.addressingProblems(in: image).isEmpty, "hdiutil's own order breaks the addresses in the IFO files")
        try DVDImageOrder.reorder(image: image)
        #expect(try DVDImageOrder.addressingProblems(in: image) == [], "after reordering every IFO address lands on its file")
        let after = try DVDImageOrder.listing(of: image)
        #expect(after.map(\.name) == DVDImageOrder.order(after.map(\.name)), "in DVD order: \(after.map(\.name))")
        #expect(after.first.map { String($0.name.split(separator: ";")[0]) } == "VIDEO_TS.IFO")
        for (a, b) in zip(after, after.dropFirst()) { #expect(a.lba + a.sectors == b.lba, "no gaps") }
        #expect(try DVDImageOrder.reorder(image: image) == false, "already in order the second time")

        // Mount the result (macOS reads it through UDF) and compare every file with its original.
        let mount = work.appending(path: "mount")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        #expect(try run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-mountpoint", mount.path, image.path]) == 0)
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
        for entry in after {
            let name = String(entry.name.split(separator: ";")[0])
            #expect(try sha(mount.appending(path: "VIDEO_TS/\(name)")) == sha(video.appending(path: name)), "\(name) reads back the same")
        }
        // And the ISO 9660 side, read directly: each file's bytes at its listed place.
        let raw = try FileHandle(forReadingFrom: image)
        defer { try? raw.close() }
        for entry in after {
            let name = String(entry.name.split(separator: ";")[0])
            try raw.seek(toOffset: UInt64(entry.lba) * 2_048)
            let bytes = try raw.read(upToCount: entry.size) ?? Data()
            let original = try Data(contentsOf: video.appending(path: name))
            #expect(bytes == original, "\(name) is where ISO 9660 says")
        }
    }
}

/// Set RIPPLE_ORDER_IMAGE to the path of a real disc image made by dvdauthor and hdiutil to check it end to end.
@Suite struct DVDImageOrderRealImageTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RIPPLE_ORDER_IMAGE"] != nil))
    func aRealDiscImageEndsUpInOrderWithTheAddressesRight() throws {
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RIPPLE_ORDER_IMAGE"]!)
        let copy = FileManager.default.temporaryDirectory.appending(path: "ripple-real-order-\(UUID().uuidString).iso")
        try FileManager.default.copyItem(at: source, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        /// A hash of every file's bytes, read straight from the image at the place the folder says.
        func hashes(_ image: URL) throws -> [String: String] {
            let handle = try FileHandle(forReadingFrom: image)
            defer { try? handle.close() }
            var out: [String: String] = [:]
            for entry in try DVDImageOrder.listing(of: image) {
                try handle.seek(toOffset: UInt64(entry.lba) * 2_048)
                var hasher = SHA256(), left = entry.size
                while left > 0 {
                    let chunk = try handle.read(upToCount: min(left, 4 << 20)) ?? Data()
                    hasher.update(data: chunk); left -= chunk.count
                }
                out[String(entry.name.split(separator: ";")[0])] = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            }
            return out
        }
        let hashesBefore = try hashes(copy)
        let before = try DVDImageOrder.addressingProblems(in: copy)
        print("PROBLEMS BEFORE:", before)
        let start = Date()
        try DVDImageOrder.reorder(image: copy)
        print("REORDER SECONDS:", Date().timeIntervalSince(start))
        #expect(try hashes(copy) == hashesBefore, "every file's bytes are unchanged")
        let after = try DVDImageOrder.addressingProblems(in: copy)
        print("PROBLEMS AFTER:", after)
        #expect(after == [])
        let listing = try DVDImageOrder.listing(of: copy)
        print("ORDER:", listing.map { "\($0.name)@\($0.lba)" })
        #expect(listing.first.map { $0.name.hasPrefix("VIDEO_TS.IFO") } == true)
    }
}
