import Foundation

/// The picture shape a Blu-ray disc is made in. One shape serves the whole disc, chosen from the first video's frame rate,
/// because the disc plays the videos as one continuous program.
public struct BluRayMode: Equatable, Sendable {
    public var width: Int
    public var height: Int
    /// As ffmpeg writes a frame rate, and as tsMuxeR writes it.
    public var frameRate: String
    public var fps: String
    /// 1080i discs carry progressive pictures flagged as interlaced, which is how a 25 or 30 frame video is allowed on a Blu-ray.
    public var interlaced: Bool

    public var title: String { "\(height)\(interlaced ? "i" : "p")\(fps)" }
    public var framesPerSecond: Double { fps == "23.976" ? 24_000.0 / 1_001 : fps == "29.97" ? 30_000.0 / 1_001 : fps == "59.94" ? 60_000.0 / 1_001 : Double(fps) ?? 24 }

    /// The nearest frame rate Blu-ray allows: 24 and 23.976 are 1080p24, 25 and 30 are 1080i, and 50 and 60 are 720p.
    public static func suggest(for files: [VideoFile]) -> BluRayMode {
        let fps = files.first?.framesPerSecond ?? 24
        switch fps {
        case ..<24.5: return BluRayMode(width: 1920, height: 1080, frameRate: "24000/1001", fps: "23.976", interlaced: false)
        case ..<27: return BluRayMode(width: 1920, height: 1080, frameRate: "25", fps: "25", interlaced: true)
        case ..<40: return BluRayMode(width: 1920, height: 1080, frameRate: "30000/1001", fps: "29.97", interlaced: true)
        case ..<55: return BluRayMode(width: 1280, height: 720, frameRate: "50", fps: "50", interlaced: false)
        default: return BluRayMode(width: 1280, height: 720, frameRate: "60000/1001", fps: "59.94", interlaced: false)
        }
    }
}

public enum BluRayAuthoring {
    /// Converts one video to a Matroska file holding HD H.264 picture and AC-3 sound. (tsMuxeR needs the picture and sound together in a
    /// container; given bare streams it writes a disc whose playlist is empty.) The picture is fitted without stretching, and a video
    /// with no sound gets silence, since the disc plays the videos as one program.
    public static func convertArguments(input: URL, output: URL, mode: BluRayMode, videoKbps: Int, hasAudio: Bool, seconds: Double) -> [String] {
        let filter = "scale=\(mode.width):\(mode.height):force_original_aspect_ratio=decrease:flags=lanczos,pad=\(mode.width):\(mode.height):(ow-iw)/2:(oh-ih)/2:black,setsar=1,fps=\(mode.frameRate),format=yuv420p"
        let gop = Int(mode.framesPerSecond.rounded())
        var params = "bluray-compat=1:keyint=\(gop):open-gop=0:slices=4:aud=1:nal-hrd=vbr:colorprim=bt709:transfer=bt709:colormatrix=bt709"
        if mode.interlaced { params += ":fake-interlaced=1" }
        var args = ["-y", "-hide_banner", "-loglevel", "error", "-nostats", "-progress", "pipe:1", "-i", input.path]
        if !hasAudio { args += ["-f", "lavfi", "-t", String(format: "%.3f", seconds), "-i", "anullsrc=r=48000:cl=stereo"] }
        args += ["-map", "0:v:0", "-map", hasAudio ? "0:a:0" : "1:a:0", "-vf", filter, "-c:v", "libx264", "-profile:v", "high", "-level:v", "4.1", "-preset", "medium",
                 "-b:v", "\(videoKbps)k", "-maxrate", "\(max(videoKbps, 1))k", "-bufsize", "30000k", "-x264-params", params,
                 "-c:a", "ac3", "-b:a", "\(VideoDiscFormat.bluray.audioKbps)k", "-ar", "48000", "-ac", "2", "-f", "matroska", output.path]
        return args
    }

    /// "00:10:23.000", the way tsMuxeR writes a chapter time.
    public static func chapterTime(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d:%02d.000", total / 3_600, (total % 3_600) / 60, total % 60)
    }

    /// The instructions for tsMuxeR: one program made of every video in order, a chapter at the start of each, written as a Blu-ray image.
    /// `files` are the converted Matroska files, named inside the folder tsMuxeR runs in; `seconds` is each video's length.
    public static func metaFile(files: [String], seconds: [Double], mode: BluRayMode, label: String) -> String {
        var starts: [Double] = [0], at = 0.0
        for length in seconds.dropLast() { at += length; starts.append(at) }
        let chapters = starts.map(chapterTime).joined(separator: ";")
        let joined = files.map { "\"\($0)\"" }.joined(separator: "+")
        return """
        MUXOPT --no-pcr-on-video-pid --new-audio-pes --blu-ray --vbr --custom-chapters=\(chapters) --label="\(label)"
        V_MPEG4/ISO/AVC, \(joined), fps=\(mode.fps), insertSEI, contSPS, track=1
        A_AC3, \(joined), track=2

        """
    }
}
