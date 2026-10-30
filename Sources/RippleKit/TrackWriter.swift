import AudioToolbox
import Foundation

public enum RipFormat: String, CaseIterable, Identifiable, Sendable {
    case mp3, m4a

    public var id: String { rawValue }
    public var fileExtension: String { rawValue }
    public var title: String { self == .mp3 ? "MP3" : "M4A" }
}

/// Takes the PCM of one track and turns it into a finished audio file.
public protocol TrackWriter: AnyObject {
    /// 16-bit stereo 44.1 kHz PCM, in order.
    func write(_ pcm: Data) throws
    /// Completes the file. Called once, after the last `write`.
    func finish() async throws
}

/// MP3 through LAME. The ID3 tag, when there is one, goes first, then the audio; the
/// Xing/LAME frame LAME reserves at the start of the audio is filled in at the end.
final class MP3TrackWriter: TrackWriter {
    private let handle: FileHandle
    private let encoder: MP3Encoder
    private let audioStart: UInt64

    init(url: URL, quality: MP3Encoder.Quality, id3: Data = Data()) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
        }
        handle = try FileHandle(forWritingTo: url)
        encoder = try MP3Encoder(quality: quality)
        if !id3.isEmpty { try handle.write(contentsOf: id3) }
        audioStart = UInt64(id3.count)
    }

    deinit { try? handle.close() }

    func write(_ pcm: Data) throws {
        try handle.write(contentsOf: try encoder.encode(pcm))
    }

    func finish() async throws {
        let (tail, tag) = try encoder.finish()
        try handle.write(contentsOf: tail)
        if !tag.isEmpty {
            try handle.seek(toOffset: audioStart)
            try handle.write(contentsOf: tag)
        }
        try handle.close()
    }
}

/// AAC in an MP4 container (.m4a) through Core Audio.
final class M4ATrackWriter: TrackWriter {
    enum WriterError: Error { case setup(OSStatus), write(OSStatus) }

    private var file: ExtAudioFileRef?

    /// `bitRate` is in bits per second for the stereo stream.
    init(url: URL, bitRate: UInt32 = 256_000) throws {
        var output = AudioStreamBasicDescription(
            mSampleRate: 44_100, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: 1_024, mBytesPerFrame: 0,
            mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        var created: ExtAudioFileRef?
        var status = ExtAudioFileCreateWithURL(url as CFURL, kAudioFileM4AType, &output, nil,
                                               AudioFileFlags.eraseFile.rawValue, &created)
        guard status == noErr, let created else { throw WriterError.setup(status) }
        file = created

        var client = AudioStreamBasicDescription(
            mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        status = ExtAudioFileSetProperty(created, kExtAudioFileProperty_ClientDataFormat,
                                         UInt32(MemoryLayout.size(ofValue: client)), &client)
        guard status == noErr else { throw WriterError.setup(status) }

        var converter: AudioConverterRef?
        var size = UInt32(MemoryLayout<AudioConverterRef?>.size)
        if ExtAudioFileGetProperty(created, kExtAudioFileProperty_AudioConverter, &size, &converter) == noErr, let converter {
            var rate = bitRate
            AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &rate)
            // Tell the file the converter changed.
            var config: CFArray?
            ExtAudioFileSetProperty(created, kExtAudioFileProperty_ConverterConfig, UInt32(MemoryLayout<CFArray?>.size), &config)
        }
    }

    deinit {
        if let file { ExtAudioFileDispose(file) }
    }

    func write(_ pcm: Data) throws {
        guard let file else { return }
        var data = pcm
        let frames = UInt32(pcm.count / 4)
        let status = data.withUnsafeMutableBytes { raw -> OSStatus in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
            return ExtAudioFileWrite(file, frames, &list)
        }
        guard status == noErr else { throw WriterError.write(status) }
    }

    func finish() async throws {
        if let file { ExtAudioFileDispose(file) }
        file = nil
    }
}
