import AppKit
import RippleKit
import SwiftUI

/// The build is running: what it is doing, one bar, and Cancel.
struct DVDBuilding: View {
    @Environment(DVDModel.self) private var dvd
    let stage: DVDBuildStage
    let fraction: Double

    var body: some View {
        VStack(spacing: Space.lg) {
            Text("Building the Disc").font(.title2.bold())
            Text(stageText).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            ProgressView(value: fraction).frame(width: 320)
            if let left = dvd.timeLeftText() { Text(left).font(.callout).foregroundStyle(.secondary) }
            Button("Cancel") { dvd.cancelBuild() }.keyboardShortcut(.cancelAction)
                .help("Stop building the disc (Esc)")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
    }

    private var stageText: String {
        switch stage {
        case .checking: "Checking the videos\u{2026}"
        case .pictures: "Making pictures for the menu\u{2026}"
        case .menus: "Drawing the menu\u{2026}"
        case .converting(let title, let of, let name, _): "Converting \u{201C}\(name)\u{201D} (\(title) of \(of))\u{2026}"
        case .authoring: "Writing the disc files\u{2026}"
        case .imaging: "Making the disc image\u{2026}"
        case .done: "Finishing\u{2026}"
        }
    }
}

/// The disc is made: burn it, or save it as an image.
struct DVDReady: View {
    @Environment(DVDModel.self) private var dvd
    @Environment(BurnModel.self) private var burn
    @State private var confirmingDiscard = false
    let result: DVDBuildResult

    /// Why Burn Disc is off: no blank DVD, a CD, or a disc that is too small. Save Disc Image works either way.
    private var problem: String? {
        let size = (try? result.image.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return burn.imageProblem(bytes: size)
    }

    var body: some View {
        ContentUnavailableView {
            Label("Disc Ready", systemImage: "checkmark.circle")
        } description: {
            VStack(spacing: Space.xs) {
                Text("Your Video DVD is ready: \(result.titles) \(result.titles == 1 ? "video" : "videos"), \(DVDPlan.approximateText(dvd.totalSeconds)).")
                if let saved = dvd.savedImage {
                    Label("Saved as \(saved.lastPathComponent).", systemImage: "checkmark").foregroundStyle(.secondary)
                }
            }
        } actions: {
            VStack(spacing: Space.md) {
              HStack {
                Button("Burn Disc") { burn.burnImage(result.image, volumeName: dvd.cleanDiscName) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil)
                    .help(problem ?? "Burn the disc to the blank DVD in the drive")
                Button("Save Disc Image\u{2026}") { dvd.chooseImageDestination() }
                    .help("Save the disc as an .iso file to open in a DVD player app or burn later")
                if let saved = dvd.savedImage {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([saved]) }
                }
                Button("Start Over") {
                    if dvd.hasUnsavedDisc { confirmingDiscard = true } else { dvd.startOver() }
                }
              }
              .fixedSize()
              if let problem {
                  Label(problem, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(Surface.warning)
              }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog("Discard the Finished Disc?", isPresented: $confirmingDiscard) {
            Button("Discard", role: .destructive) { dvd.startOver() }
            Button("Keep Disc", role: .cancel) {}
        } message: {
            Text("The disc has not been burned or saved. If you start over, it is lost.")
        }
    }
}
