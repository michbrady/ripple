import CLame
import Foundation

/// Encodes 16-bit stereo 44.1 kHz PCM to MP3 with LAME.
/// Write `encode` output to the file as it comes, then `finish`, then write the
/// returned tag frame over the start of the file so players know the length.
public final class MP3Encoder {
    public enum Quality: Equatable, Sendable {
        /// 0 is best and largest, 9 is smallest. 2 sounds transparent for most people.
        case vbr(Int)
        /// A fixed rate in kilobits per second.
        case cbr(Int)
    }

    public enum EncoderError: Error { case setupFailed, encodeFailed(Int32) }

    private let flags: lame_t

    public init(quality: Quality = .vbr(2)) throws {
        guard let flags = lame_init() else { throw EncoderError.setupFailed }
        self.flags = flags
        lame_set_in_samplerate(flags, 44_100)
        lame_set_num_channels(flags, 2)
        lame_set_quality(flags, 2)
        switch quality {
        case .vbr(let level):
            lame_set_VBR(flags, vbr_mtrh)
            lame_set_VBR_q(flags, Int32(min(max(level, 0), 9)))
        case .cbr(let kbps):
            lame_set_VBR(flags, vbr_off)
            lame_set_brate(flags, Int32(kbps))
        }
        guard lame_init_params(flags) >= 0 else { throw EncoderError.setupFailed }
    }

    deinit { lame_close(flags) }

    /// Encodes interleaved PCM (left, right, left, right, ...). Returns the MP3 bytes ready so far.
    public func encode(_ pcm: Data) throws -> Data {
        var samples = [Int16](repeating: 0, count: pcm.count / 2)
        _ = samples.withUnsafeMutableBytes { pcm.copyBytes(to: $0) }
        let frames = Int32(samples.count / 2)
        var out = [UInt8](repeating: 0, count: Int(Double(frames) * 1.25) + 7_200)
        let written = lame_encode_buffer_interleaved(flags, &samples, frames, &out, Int32(out.count))
        guard written >= 0 else { throw EncoderError.encodeFailed(written) }
        return Data(out[0..<Int(written)])
    }

    /// Flushes the last frames. `tag` is the Xing/LAME frame to write at byte 0 of the file.
    public func finish() throws -> (tail: Data, tag: Data) {
        var out = [UInt8](repeating: 0, count: 7_200)
        let written = lame_encode_flush(flags, &out, Int32(out.count))
        guard written >= 0 else { throw EncoderError.encodeFailed(written) }
        var tag = [UInt8](repeating: 0, count: 4_096)
        let tagSize = lame_get_lametag_frame(flags, &tag, tag.count)
        return (Data(out[0..<Int(written)]), Data(tag[0..<min(tagSize, tag.count)]))
    }
}
