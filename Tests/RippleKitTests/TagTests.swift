import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import RippleKit

/// Writes tags, then reads them back with Apple's AVFoundation (not with this project's own code).
@Suite struct TagTests {
    static func png(size: Int = 64) -> Data {
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.1, green: 0.6, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    /// A noisy picture that does not compress, so the PNG is a few hundred kilobytes.
    static func bigPNG(size: Int = 300) -> Data {
        var generator = SystemRandomNumberGenerator()
        var pixels = [UInt8](repeating: 255, count: size * size * 4)
        for index in 0..<(size * size) {
            pixels[index * 4] = UInt8.random(in: 0...255, using: &generator)
            pixels[index * 4 + 1] = UInt8.random(in: 0...255, using: &generator)
            pixels[index * 4 + 2] = UInt8.random(in: 0...255, using: &generator)
        }
        let context = pixels.withUnsafeMutableBytes {
            CGContext(data: $0.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        }
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    static func request(folder: URL, format: RipFormat, cover: Data? = png(), compilation: Bool = false, discs: (Int, Int) = (1, 1)) -> RipRequest {
        var request = RipperTests.request(disc: FixtureDisc(trackSeconds: [2, 2]), folder: folder, titles: ["Low A é", "High C"])
        request.format = format
        request.albumArtist = compilation ? "Various Artists" : "The Tones"
        request.album = "Sine Waves"
        request.year = "2020"
        request.cover = cover
        request.isCompilation = compilation
        request.discNumber = discs.0
        request.discCount = discs.1
        request.tracks[0].artist = "Ana"
        return request
    }

    static func items(_ url: URL) async throws -> [AVMetadataItem] {
        try await AVURLAsset(url: url).load(.metadata)
    }

    static func string(_ items: [AVMetadataItem], _ id: AVMetadataIdentifier) async throws -> String? {
        try await AVMetadataItem.metadataItems(from: items, filteredByIdentifier: id).first?.load(.stringValue)
    }

    static func data(_ items: [AVMetadataItem], _ id: AVMetadataIdentifier) async throws -> Data? {
        try await AVMetadataItem.metadataItems(from: items, filteredByIdentifier: id).first?.load(.dataValue)
    }

    // MARK: MP3

    @Test func mp3CarriesItsTags() async throws {
        let folder = try RipperTests.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cover = Self.png()
        let files = try await Ripper.rip(Self.request(folder: folder, format: .mp3, cover: cover), onEvent: { _ in })
        let items = try await Self.items(files[0])
        #expect(try await Self.string(items, .id3MetadataTitleDescription) == "Low A é")
        #expect(try await Self.string(items, .id3MetadataLeadPerformer) == "Ana")
        #expect(try await Self.string(items, .id3MetadataAlbumTitle) == "Sine Waves")
        #expect(try await Self.string(items, .id3MetadataBand) == "The Tones")
        #expect(try await Self.string(items, .id3MetadataTrackNumber) == "1/2")
        #expect(try await Self.data(items, .id3MetadataAttachedPicture) == cover)
        let second = try await Self.items(files[1])
        #expect(try await Self.string(second, .id3MetadataLeadPerformer) == "The Tones", "a track with no artist uses the album artist")
        #expect(try await Self.string(second, .id3MetadataTrackNumber) == "2/2")
    }

    @Test func mp3WithTagsStillHasTheRightLength() async throws {
        let folder = try RipperTests.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try await Ripper.rip(Self.request(folder: folder, format: .mp3), onEvent: { _ in })
        let file = try AVAudioFile(forReading: files[0])
        #expect(abs(Double(file.length) / file.processingFormat.sampleRate - 2.0) < 0.15)
        let asset = try await AVURLAsset(url: files[0]).load(.duration)
        #expect(abs(asset.seconds - 2.0) < 0.15, "\(asset.seconds) s")
    }

    @Test func mp3MarksDiscSetsAndCompilations() async throws {
        let folder = try RipperTests.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try await Ripper.rip(Self.request(folder: folder, format: .mp3, compilation: true, discs: (2, 3)), onEvent: { _ in })
        let items = try await Self.items(files[0])
        #expect(try await Self.string(items, .id3MetadataPartOfASet) == "2/3")
        #expect(try await Self.string(items, .id3MetadataBand) == "Various Artists")
        #expect(AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .id3MetadataYear).count + AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .id3MetadataRecordingTime).count >= 1)
    }

    @Test func mp3WithoutCoverOrDetailsStillPlays() async throws {
        let folder = try RipperTests.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var request = Self.request(folder: folder, format: .mp3, cover: nil)
        request.album = ""
        request.albumArtist = ""
        request.year = ""
        let files = try await Ripper.rip(request, onEvent: { _ in })
        let items = try await Self.items(files[0])
        #expect(try await Self.data(items, .id3MetadataAttachedPicture) == nil)
        #expect(try await Self.string(items, .id3MetadataAlbumTitle) == nil)
        #expect(try await Self.string(items, .id3MetadataTitleDescription) == "Low A é")
        _ = try AVAudioFile(forReading: files[0])
    }

    @Test func id3FramesUseSyncsafeSizes() {
        #expect(ID3Tag.syncsafe(0) == [0, 0, 0, 0])
        #expect(ID3Tag.syncsafe(127) == [0, 0, 0, 127])
        #expect(ID3Tag.syncsafe(128) == [0, 0, 1, 0])
        #expect(ID3Tag.syncsafe(300_000) == [0, 0x12, 0x27, 0x60])
        let tag = ID3Tag.make(TrackTags(title: "T"))
        #expect(Array(tag.prefix(5)) == Array("ID3".utf8) + [4, 0])
        #expect(ID3Tag.make(TrackTags(title: "")).isEmpty)
    }

    // MARK: M4A

    @Test func m4aCarriesItsTags() async throws {
        let folder = try RipperTests.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cover = Self.png()
        let files = try await Ripper.rip(Self.request(folder: folder, format: .m4a, cover: cover), onEvent: { _ in })
        let items = try await Self.items(files[0])
        #expect(try await Self.string(items, .iTunesMetadataSongName) == "Low A é")
        #expect(try await Self.string(items, .iTunesMetadataArtist) == "Ana")
        #expect(try await Self.string(items, .iTunesMetadataAlbum) == "Sine Waves")
        #expect(try await Self.string(items, .iTunesMetadataAlbumArtist) == "The Tones")
        #expect(try await Self.data(items, .iTunesMetadataCoverArt) == cover)
        let number = try await Self.data(items, .iTunesMetadataTrackNumber)
        #expect(number.map { [UInt8]($0) } == [0, 0, 0, 1, 0, 2, 0, 0], "track 1 of 2")
    }

    @Test func m4aWithTagsStillHasTheRightLength() async throws {
        let folder = try RipperTests.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try await Ripper.rip(Self.request(folder: folder, format: .m4a), onEvent: { _ in })
        let file = try AVAudioFile(forReading: files[0])
        #expect(abs(Double(file.length) / file.processingFormat.sampleRate - 2.0) < 0.15)
        let duration = try await AVURLAsset(url: files[0]).load(.duration)
        #expect(abs(duration.seconds - 2.0) < 0.15, "\(duration.seconds) s")
    }

    @Test func m4aMarksDiscSetsAndCompilations() async throws {
        let folder = try RipperTests.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try await Ripper.rip(Self.request(folder: folder, format: .m4a, compilation: true, discs: (2, 3)), onEvent: { _ in })
        let items = try await Self.items(files[0])
        let disc = try await Self.data(items, .iTunesMetadataDiscNumber)
        #expect(disc.map { [UInt8]($0) } == [0, 0, 0, 2, 0, 3], "disc 2 of 3")
        let bytes = try Data(contentsOf: files[0])
        #expect(bytes.range(of: Data("cpil".utf8)) != nil, "the compilation flag is present")
    }

    @Test func aCoverBiggerThanCoreAudiosPaddingStillWorks() async throws {
        let cover = Self.bigPNG()
        #expect(cover.count > 100_000, "the test cover is \(cover.count) bytes")
        for format in RipFormat.allCases {
            let folder = try RipperTests.tempFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let files = try await Ripper.rip(Self.request(folder: folder, format: format, cover: cover), onEvent: { _ in })
            let items = try await Self.items(files[0])
            let picture = try await Self.data(items, format == .mp3 ? .id3MetadataAttachedPicture : .iTunesMetadataCoverArt)
            #expect(picture == cover, "\(format.title) cover")
            let file = try AVAudioFile(forReading: files[0])
            #expect(abs(Double(file.length) / file.processingFormat.sampleRate - 2.0) < 0.15, "\(format.title) length")
            // Decoding the whole file proves the chunk offsets point at real audio.
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buffer)
            #expect(buffer.frameLength > 80_000, "\(format.title) decoded \(buffer.frameLength) frames")
        }
    }

    @Test func mp4TaggerRefusesFilesItCannotTag() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "ripple-not-mp4-\(UUID().uuidString).m4a")
        try Data("this is not an mp4 file at all".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: (any Error).self) { try MP4Tagger.apply(TrackTags(title: "x"), to: url) }
    }
}
