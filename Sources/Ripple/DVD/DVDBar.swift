import AppKit
import RippleKit
import SwiftUI

/// How full the disc is and how good the picture will be, then the drive.
struct DVDBar: View {
    @Environment(BurnModel.self) private var burn
    @Environment(DVDModel.self) private var dvd

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            if !dvd.videos.isEmpty { fit }
            if !dvd.videos.isEmpty { dvd.format == .dvd ? AnyView(choices) : AnyView(pictureNote) }
            HStack(spacing: Space.md) {
                Image(systemName: burn.isReady ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(burn.isReady ? Color.secondary : Surface.warning)
                Text(burn.deviceLine).lineLimit(2)
                Spacer()
                Button("Build Disc") { dvd.build(on: burn.deviceState) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!dvd.canBuild(on: burn.deviceState))
                    .help(dvd.canBuild(on: burn.deviceState) ? "Convert the videos and make the disc (⌘B)" : "Add videos that fit on the disc to build it")
            }
        }
        .padding(Space.lg)
    }

    /// TV Standard and screen shape, with what they were guessed from.
    private var choices: some View {
        @Bindable var dvd = dvd
        return VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.lg) {
                Picker("TV Standard", selection: Binding(get: { dvd.standard }, set: { dvd.standardChoice = $0 })) {
                    Text("NTSC (US)").tag(TVStandard.ntsc)
                    Text("PAL (Europe)").tag(TVStandard.pal)
                }
                .fixedSize()
                .help("The kind of TV the disc is made for")
                Picker("Screen", selection: Binding(get: { dvd.widescreen }, set: { dvd.widescreenChoice = $0 })) {
                    Text("Widescreen (16:9)").tag(true)
                    Text("Standard (4:3)").tag(false)
                }
                .fixedSize()
                .help("The shape of the picture. Videos of another shape get bars, never stretching")
                Spacer()
            }
            if let note = dvd.mixedNote {
                Label(note, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// A Blu-ray is made in one HD shape, chosen from the first video; there is nothing to pick.
    private var pictureNote: some View {
        Label("The disc is made in \(dvd.bluRayMode.title) high definition, from the first video. It plays at once, with no menu, and each video is also a title that players with a title list can pick.", systemImage: "info.circle")
            .font(.callout).foregroundStyle(.secondary)
    }

    private var fit: some View {
        let plan = dvd.plan(on: burn.deviceState)
        let tooLong: Bool = { if case .tooLong = plan.fit { true } else { false } }()
        return VStack(alignment: .leading, spacing: Space.xs) {
            ProgressView(value: min(1, plan.usedFraction))
                .tint(tooLong ? Surface.warning : nil)
                .accessibilityLabel("Disc capacity")
                .accessibilityValue(summary(plan))
            HStack(spacing: Space.xs) {
                Text(summary(plan)).monospacedDigit().foregroundStyle(.secondary)
                if case .tooLong(let seconds) = plan.fit {
                    Label("Too long by \(DVDPlan.approximateText(seconds)). Remove a video or use a \(dvd.format == .dvd ? "dual-layer disc" : "50 GB disc").", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Surface.warning)
                }
            }
            .font(.callout)
            if plan.quality == .reduced {
                Label("Reduced quality: the picture is softer to fit everything.", systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
            }
            if !isRightDisc { Label(dvd.format == .dvd ? "Based on a single-layer DVD." : "Based on a 25 GB Blu-ray disc.", systemImage: "info.circle").font(.callout).foregroundStyle(.secondary) }
        }
    }

    private var isRightDisc: Bool {
        if case .ready(let media) = burn.deviceState { return media.kind == burn.type.mediaKind }
        return false
    }

    private func summary(_ plan: DVDPlan) -> String {
        let used = DVDPlan.approximateText(plan.totalSeconds), room = DVDPlan.approximateText(plan.longestReducedSeconds)
        if case .tooLong = plan.fit { return "\(used) of \(room)" }
        return "\(used) of \(room) \u{00B7} \(plan.quality.title)"
    }
}
