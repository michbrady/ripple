import AppKit
import AVFoundation
import Foundation
import ImageIO
import RippleKit
import UniformTypeIdentifiers

@MainActor
extension SelfTest {
    /// S-002 to S-004 on a real music CD. Read-only.
    static func realCDChecks(model: AppModel) async {
        let fm = FileManager.default
        let out = fm.temporaryDirectory.appending(path: "ripple-realcd-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? fm.createDirectory(at: out, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: out) }
        model.outputFolder = out

        // S-002: the app notices the disc and shows its tracks by itself.
        await wait(until: { model.hasDisc && model.phase == .ready }, seconds: 30)
        check("the app detects the inserted disc and shows its tracks", model.hasDisc && model.phase == .ready, "\(model.phase)")
        guard let disc = model.disc else { return }
        let toc = disc.toc
        print("INFO tracks on screen: \(model.rows.count), TOC entries: \(toc.entries.count), audio: \(toc.audioTracks.count), lead-out: \(toc.leadOut)")
        print("INFO first entries: \(toc.entries.prefix(3).map { "#\($0.number)@\($0.lba)\($0.isAudio ? "" : " DATA")" })")
        print("INFO last entries: \(toc.entries.suffix(3).map { "#\($0.number)@\($0.lba)\($0.isAudio ? "" : " DATA")" })")
        print("INFO MusicBrainz disc ID: \(toc.discID)")
        print("INFO MusicBrainz toc: \(toc.musicBrainzTOC.prefix(80))...")

        // S-003: the table of contents.
        check("the track list has one row per audio track", model.rows.count == toc.audioTracks.count && !model.rows.isEmpty)
        check("every track has a plausible length", model.rows.allSatisfy { $0.seconds > 1 && $0.seconds < 3_600 })
        let total = toc.audioTracks.indices.reduce(0.0) { $0 + toc.seconds(ofTrack: $1) }
        print("INFO total audio time: \(Int(total / 60)) min \(Int(total) % 60) s")

        // The lookup runs against the real MusicBrainz.
        await wait(until: { model.lookupState != .searching && model.lookupState != .idle }, seconds: 30)
        print("INFO lookup: \(model.lookupState), matches: \(model.matches.count), album: \(model.albumTitle) / \(model.albumArtist)")

        // S-004: raw reads. Compare with the system's own copy of the audio (the .aiff files the CD filesystem shows).
        // macOS names the volume after the disc ("Audio CD", or the album once it is identified): find it by its .aiff files.
        let volume = ((try? fm.contentsOfDirectory(atPath: "/Volumes")) ?? []).map { URL(fileURLWithPath: "/Volumes/\($0)", isDirectory: true) }
            .first { ((try? fm.contentsOfDirectory(atPath: $0.path)) ?? []).contains { $0.hasSuffix(".aiff") } }
            ?? URL(fileURLWithPath: "/Volumes/Audio CD", isDirectory: true)
        print("INFO the system's copy of the audio is at: \(volume.lastPathComponent)")
        let aiffs = ((try? fm.contentsOfDirectory(atPath: volume.path)) ?? []).filter { $0.hasSuffix(".aiff") }
        let first = aiffs.first { $0.hasPrefix("1 ") }
        let range = toc.sectors(ofTrack: 0)
        let probe = 300
        let a = try? disc.readSectors(start: range.lowerBound + 1_000, count: probe)
        let b = try? disc.readSectors(start: range.lowerBound + 1_000, count: probe)
        check("a raw read returns exactly sectors times 2352 bytes", a?.count == probe * 2_352, "\(a?.count ?? -1)")
        check("reading the same sectors twice gives the same bytes", a != nil && a == b)
        if let first, let a, let pcm = aiffPCM(volume.appending(path: first)) {
            let offset = 1_000 * 2_352
            let swapped = Data(pcm[pcm.startIndex + offset ..< min(pcm.endIndex, pcm.startIndex + offset + probe * 2_352)])
            check("raw audio matches the system's copy of track 1, byte for byte", swapped == a, "\(swapped.count) vs \(a.count) bytes")
            // Stress: many reads from scattered places, each compared to the system's copy.
            var trials = 0, badTrials = 0, badSectors = 0
            var firstBad: [String] = []
            var generator = SystemRandomNumberGenerator()
            let usable = range.count - 330
            for _ in 0..<40 {
                let startSector = Int.random(in: 0..<usable, using: &generator)
                guard let read = try? disc.readSectors(start: range.lowerBound + startSector, count: 300) else { continue }
                trials += 1
                var bad: [Int] = []
                for index in 0..<300 {
                    let theirs = pcm[pcm.startIndex + (startSector + index) * 2_352 ..< pcm.startIndex + (startSector + index + 1) * 2_352]
                    if Data(theirs) != read[index * 2_352 ..< (index + 1) * 2_352] { bad.append(index) }
                }
                if !bad.isEmpty {
                    badTrials += 1
                    badSectors += bad.count
                    if firstBad.count < 6 { firstBad.append("start \(startSector): \(bad.count) bad at read positions \(bad.prefix(5))..\(bad.last ?? 0)") }
                }
            }
            print("INFO stress: \(trials) reads of 300 sectors from random places; \(badTrials) had differences, \(badSectors) sectors differ in all")
            for line in firstBad { print("INFO   \(line)") }
            check("40 scattered raw reads all match the system's copy", trials > 0 && badTrials == 0, "\(badTrials) of \(trials) reads differed")
            // Which sectors differ, for reads that start at different places?
            for startSector in [980, 1_000, 1_010, 1_017, 1_018, 1_500, 5_000, 7_700] {
                guard let read = try? disc.readSectors(start: range.lowerBound + startSector, count: 100) else { continue }
                var bad: [Int] = []
                for index in 0..<100 {
                    let theirs = pcm[pcm.startIndex + (startSector + index) * 2_352 ..< pcm.startIndex + (startSector + index + 1) * 2_352]
                    if Data(theirs) != read[index * 2_352 ..< (index + 1) * 2_352] { bad.append(index) }
                }
                let shown = bad.count > 24 ? "\(bad.prefix(24)) ..." : "\(bad)"
                print("INFO read of 100 sectors from track sector \(startSector): \(bad.count) differ, at read positions \(shown)")
            }
            if swapped != a {
                let first = zip(swapped, a).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? -1
                let differing = zip(swapped, a).reduce(0) { $0 + ($1.0 != $1.1 ? 1 : 0) }
                print("INFO first differing byte: \(first) of \(a.count); differing bytes: \(differing)")
                // Is it the same audio, shifted by some frames (4 bytes each)?
                let window = 20_000
                let middle = a.count / 2
                let target = Data(a[middle ..< middle + window])
                var found: Int?
                for shift in -6_000...6_000 {
                    let start = middle + shift * 4
                    if start >= 0, start + window <= swapped.count, Data(swapped[swapped.startIndex + start ..< swapped.startIndex + start + window]) == target { found = shift; break }
                }
                print("INFO the raw read matches the system copy when shifted by: \(found.map { "\($0) frames" } ?? "no shift in +-6000 frames")")
            }
        } else {
            check("the system's copy of track 1 could be read for comparison", false, "files: \(aiffs.prefix(3))")
        }
        let started = Date.now
        let sample = try? disc.readSectors(start: range.lowerBound, count: 26 * 40)
        let seconds = Date.now.timeIntervalSince(started)
        print("INFO read speed: \(Int(Double(26 * 40) / max(seconds, 0.001))) sectors/s (\(String(format: "%.1f", Double(26 * 40) / 75 / max(seconds, 0.001)))x)")
        check("a longer raw read succeeds", sample?.count == 26 * 40 * 2_352)

        if ProcessInfo.processInfo.environment["RIPPLE_REAL_CD_TIMING"] == "1" {
            // How long does track 1 (105 s of audio) take to rip, by chunk size and Check for Errors?
            let tracks = model.rows.map { RipTrack(number: $0.number, title: $0.title, include: $0.id == 0) }
            for (verify, chunk) in [(false, 26), (false, 150), (true, 26), (true, 150), (true, 300)] {
                let folder = out.appending(path: "timing-\(verify)-\(chunk)", directoryHint: .isDirectory)
                let request = RipRequest(disc: disc, tracks: tracks, albumArtist: "T", album: "T", folder: folder,
                                         quality: .vbr(2), verify: verify, chunkSectors: chunk)
                let began = Date.now
                _ = try? await Ripper.rip(request, onEvent: { _ in })
                let took = Date.now.timeIntervalSince(began)
                print("INFO timing: check for errors \(verify ? "on " : "off"), \(chunk) sectors per read: \(String(format: "%5.1f", took)) s for \(Int(model.rows[0].seconds)) s of audio = \(String(format: "%.1f", model.rows[0].seconds / took))x real time")
            }
            return
        }
        if ProcessInfo.processInfo.environment["RIPPLE_REAL_CD_SKIP_RIP"] == "1" { return }
        // A real rip of one track, with Check for Errors on.
        for index in model.rows.indices { model.rows[index].include = index < 1 }
        model.verifyReads = true
        model.format = .mp3
        let ripStart = Date.now
        model.rip()
        await wait(until: { !model.isRipping }, seconds: 300)
        print("INFO real rip of 1 track took \(String(format: "%.1f", Date.now.timeIntervalSince(ripStart))) s")
        let files = ((try? fm.enumerator(at: out, includingPropertiesForKeys: nil))?.compactMap { $0 as? URL }.filter { $0.pathExtension == "mp3" } ?? []).sorted { $0.path < $1.path }
        check("a real rip makes one MP3 per checked track", files.count == 1, "\(files.map(\.lastPathComponent))")
        check("a real rip finishes with no track needing attention", model.needsAttentionCount == 0, "\(model.rows.prefix(1).map(\.status))")
        for (file, row) in zip(files, model.rows.prefix(1)) {
            let item = await BurnScanner.read(file)
            print("INFO \(file.lastPathComponent): \(String(format: "%.2f", item?.seconds ?? 0)) s, TOC says \(String(format: "%.2f", row.seconds)) s")
            check("\(file.lastPathComponent) is as long as the disc says", item != nil && abs((item?.seconds ?? 0) - row.seconds) < 0.2)
        }
    }

    /// Reads the Mac's real burner through DiscRecordingBurner. Runs only with RIPPLE_REAL_DRIVE=1, and never writes.
    static func realDriveChecks() {
        guard ProcessInfo.processInfo.environment["RIPPLE_REAL_DRIVE"] == "1" else { return }
        let real = DiscRecordingBurner()
        let state = real.state()
        print("INFO real drive: \(real.deviceName ?? "none") -> \(state)")
        check("the real burner reports a drive when one is connected", (real.deviceName != nil) == (state != .noDrive))
        if case .ready(let media) = state {
            check("a blank disc in the real drive reports a type and free space", !media.label.isEmpty && media.blocksFree > 0, "\(media)")
        }
    }

    /// The PCM of an AIFF or AIFC file, as little-endian 16-bit samples like the raw disc reads. The CD filesystem's
    /// files are AIFC with compression type "sowt", which is already little-endian.
    static func aiffPCM(_ url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url), data.count > 12 else { return nil }
        var position = 12
        var littleEndian = false
        while position + 8 <= data.count {
            let id = String(decoding: data[position ..< position + 4], as: UTF8.self)
            let size = data[position + 4 ..< position + 8].reduce(0) { $0 << 8 | Int($1) }
            if id == "COMM", size >= 22 {
                littleEndian = String(decoding: data[position + 8 + 18 ..< position + 8 + 22], as: UTF8.self) == "sowt"
            }
            if id == "SSND" {
                let skip = data[position + 8 ..< position + 12].reduce(0) { $0 << 8 | Int($1) }
                let start = position + 16 + skip
                let pcm = Data(data[start ..< min(data.count, position + 8 + size)])
                if littleEndian { return pcm }
                var swapped = Data(capacity: pcm.count)
                var index = 0
                while index + 1 < pcm.count { swapped.append(pcm[index + 1]); swapped.append(pcm[index]); index += 2 }
                return swapped
            }
            position += 8 + size + (size % 2)
        }
        return nil
    }
}
