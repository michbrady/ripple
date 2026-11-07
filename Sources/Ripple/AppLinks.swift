import Foundation

/// Where the app points people: its web page, the page that says what it does with your information, and the tip jar.
enum AppLinks {
    static let website = URL(string: "https://www.bradysbit.com/ripple/")!
    static let privacy = URL(string: "https://www.bradysbit.com/ripple/privacy.html")!
    /// Opened in the browser only when someone chooses it. The app never asks for a tip on its own.
    static let tip = URL(string: "https://ko-fi.com/bradysbit")!
    /// The programs that make a Video DVD, credited in the About window.
    static let ffmpeg = URL(string: "https://ffmpeg.org/")!
    static let tsMuxeR = URL(string: "https://github.com/justdan96/tsMuxer")!
    static let dvdauthor = URL(string: "https://dvdauthor.sourceforge.net/")!
}
