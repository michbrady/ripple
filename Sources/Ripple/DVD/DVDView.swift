import RippleKit
import SwiftUI

/// Burn mode with Video DVD chosen: the videos for the disc, and the drive.
struct DVDView: View {
    @Environment(BurnModel.self) private var burn
    @Environment(DVDModel.self) private var dvd

    var body: some View {
        VStack(spacing: 0) {
            DiscTypeHeader()
            Divider()
            if dvd.videos.isEmpty { DVDEmpty() }
            Divider()
            DVDBar()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// The Disc Type switch with its one-line summary. Shown on every Burn page, so the choice is never hidden.
struct DiscTypeHeader: View {
    @Environment(BurnModel.self) private var burn

    var body: some View {
        @Bindable var burn = burn
        VStack(alignment: .leading, spacing: Space.xs) {
            Picker("Disc Type", selection: $burn.type) {
                ForEach(DiscType.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Text(burn.type.summary).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.margin)
    }
}

/// No videos chosen yet.
struct DVDEmpty: View {
    var body: some View {
        ContentUnavailableView {
            Label("Add Videos for the Disc", systemImage: "film")
        } description: {
            Text("Drop video files here, or choose them.")
        } actions: {
            Button("Choose Videos…") {}
                .keyboardShortcut(.defaultAction)
                .disabled(true)   // S-040
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The drive and disc on the left; Build Disc comes on the right in S-045.
struct DVDBar: View {
    @Environment(BurnModel.self) private var burn

    var body: some View {
        HStack(spacing: Space.md) {
            Image(systemName: burn.isReady ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(burn.isReady ? Color.secondary : Surface.warning)
            Text(burn.deviceLine).lineLimit(2)
            Spacer()
        }
        .padding(Space.lg)
    }
}
