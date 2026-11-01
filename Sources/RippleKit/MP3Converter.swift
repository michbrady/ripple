import AudioToolbox
import AVFoundation
import Foundation

/// Turns an audio file (M4A, or anything Core Audio reads) into an MP3 with the title, artist, and album kept.
/// Used when an M4A goes on an MP3 Disc.
public enum MP3Converter {
    public enum ConvertError: Error, Equatable { case cannotOpen(OSStatus), cannotRead(OSStatus) }

    /// 192 kbps keeps the size predictable: 24,000 bytes per second.
    public static let quality = MP3Encoder.Quality.cbr(192)

    public static func convert(_ source: URL, to destination: URL) async throws {
        let tags = await readTags(source)
        let writer = try MP3TrackWriter(url: destination, quality: quality, id3: ID3Tag.make(tags))
        do {
            try await decode(source) { try writer.write($0) }
            try await writer.finish()
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private static func readTags(_ url: URL) async -> TrackTags {
        let asset = AVURLAsset(url: url)
        let metadata = (try? await asset.load(.commonMetadata)) ?? []
        func string(_ id: AVMetadataIdentifier) async -> String {
            let text = try? await AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: id).first?.load(.stringValue)
            return text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        let title = await string(.commonIdentifierTitle)
        return TrackTags(title: title.isEmpty ? url.deletingPathExtension().lastPathComponent : title,
                         artist: await string(.commonIdentifierArtist), album: await string(.commonIdentifierAlbumName))
    }

    /// Reads the file as 16-bit stereo 44.1 kHz PCM, 16,384 frames at a time. Core Audio changes the sample rate
    /// and the number of channels.
    private static func decode(_ url: URL, _ handle: (Data) throws -> Void) async throws {
        var opened: ExtAudioFileRef?
        var status = ExtAudioFileOpenURL(url as CFURL, &opened)
        guard status == noErr, let file = opened else { throw ConvertError.cannotOpen(status) }
        defer { ExtAudioFileDispose(file) }
        var client = AudioStreamBasicDescription(
            mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        status = ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat,
                                         UInt32(MemoryLayout.size(ofValue: client)), &client)
        guard status == noErr else { throw ConvertError.cannotOpen(status) }

        let framesPerRead: UInt32 = 16_384
        var buffer = Data(count: Int(framesPerRead) * 4)
        while true {
            try Task.checkCancellation()
            var frames = framesPerRead
            status = buffer.withUnsafeMutableBytes { raw -> OSStatus in
                var list = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
                return ExtAudioFileRead(file, &frames, &list)
            }
            guard status == noErr else { throw ConvertError.cannotRead(status) }
            if frames == 0 { return }
            try handle(buffer.prefix(Int(frames) * 4))
            await Task.yield()
        }
    }
}
