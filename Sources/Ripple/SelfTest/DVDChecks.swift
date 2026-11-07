import AppKit
import Foundation
import RippleKit

/// S-039 onward: the Video DVD page, on made-up videos and a made-up burner.
@MainActor
extension SelfTest {
    static func dvdChecks(burn: BurnModel) async {
        // S-039: Video DVD is the third Disc Type, remembered, and asks for a DVD, not a CD.
        check("Disc Type has three choices, Video DVD last", DiscType.allCases.map(\.title) == ["Audio CD", "MP3 Disc", "Video DVD"])
        burn.showSnapshot(.videoEmpty)
        check("Video DVD is remembered", Store.defaults.string(forKey: "burn.type") == "video")
        check("a blank DVD-R is accepted for a Video DVD", burn.isReady && burn.deviceLine.contains("blank DVD-R"), burn.deviceLine)
        burn.showSnapshot(.empty)
        burn.type = .video
        check("a blank CD-R is refused for a Video DVD", !burn.isReady && burn.deviceLine.contains("Insert a blank DVD-R or DVD-RW"), burn.deviceLine)
        burn.showSnapshot(.empty)
        burn.type = .audio
    }
}
