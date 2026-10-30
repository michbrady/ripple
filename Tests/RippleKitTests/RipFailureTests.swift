import Foundation
import Testing
@testable import RippleKit

@Suite struct RipFailureTests {
    static let folder = URL(fileURLWithPath: "/Users/me/Music", isDirectory: true)

    @Test func aFullDiskNamesTheFolderAndAsksForAnotherOne() {
        for error in [CocoaError(.fileWriteOutOfSpace) as Error, POSIXError(.ENOSPC) as Error] {
            let failure = RipFailure.describing(error, folder: Self.folder)
            #expect(failure.message == "The disk is full, so Ripple cannot save to \u{201C}Music\u{201D}. Free some space or choose another Output Folder.")
            #expect(failure.action == .chooseFolder)
        }
    }

    @Test func anUnwritableFolderNamesTheFolder() {
        for error in [CocoaError(.fileWriteNoPermission) as Error, CocoaError(.fileWriteVolumeReadOnly) as Error,
                      POSIXError(.EACCES) as Error, POSIXError(.EROFS) as Error] {
            let failure = RipFailure.describing(error, folder: Self.folder)
            #expect(failure.message == "Ripple cannot save to \u{201C}Music\u{201D}. The folder is not writable. Choose another Output Folder.")
            #expect(failure.action == .chooseFolder)
        }
    }

    @Test func aMissingFolderSaysSo() {
        let failure = RipFailure.describing(CocoaError(.fileNoSuchFile), folder: Self.folder)
        #expect(failure.message == "The folder \u{201C}Music\u{201D} is missing. Choose another Output Folder.")
        #expect(failure.action == .chooseFolder)
    }

    @Test func aPOSIXErrorUnderACocoaErrorIsFound() {
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteUnknown.rawValue, userInfo: [NSUnderlyingErrorKey: underlying])
        #expect(RipFailure.describing(wrapped, folder: Self.folder).action == .chooseFolder)
        #expect(RipFailure.describing(wrapped, folder: Self.folder).message.hasPrefix("The disk is full"))
    }

    @Test func anythingElseSaysWhatHappenedAndOffersTryAgain() {
        struct Odd: LocalizedError { var errorDescription: String? { "The encoder stopped." } }
        let failure = RipFailure.describing(Odd(), folder: Self.folder)
        #expect(failure.message == "Unable to finish ripping. The encoder stopped.")
        #expect(failure.action == .tryAgain)
    }

    @Test func aRealUnwritableFolderIsReportedByTheRipper() async throws {
        let parent = try RipperTests.tempFolder()
        let locked = parent.appending(path: "Locked", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: parent)
        }
        let request = RipperTests.request(disc: FixtureDisc(trackSeconds: [1]), folder: locked, titles: ["A"])
        do {
            _ = try await Ripper.rip(request, onEvent: { _ in })
            Issue.record("the rip should have failed")
        } catch {
            let failure = RipFailure.describing(error, folder: locked)
            #expect(failure.action == .chooseFolder, "\(error)")
            #expect(failure.message.contains("\u{201C}Locked\u{201D}"))
        }
    }
}
