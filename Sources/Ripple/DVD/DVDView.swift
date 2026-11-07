import AppKit
import RippleKit
import SwiftUI

/// Burn mode with Video DVD chosen: the videos for the disc, and the drive.
struct DVDView: View {
    @Environment(BurnModel.self) private var burn
    @Environment(DVDModel.self) private var dvd

    var body: some View {
        @Bindable var dvd = dvd
        Group {
            switch dvd.phase {
            case .editing:
                VStack(spacing: 0) {
                    DiscTypeHeader()
                    Divider()
                    if dvd.items.isEmpty { DVDEmpty() } else { DVDList() }
                    Divider()
                    DVDBar()
                }
                .inspector(isPresented: $dvd.showsMenu) {
                    DVDMenuInspector().inspectorColumnWidth(min: 260, ideal: 320, max: 420)
                }
            case .building(let stage, let fraction):
                DVDBuilding(stage: stage, fraction: fraction)
            case .ready(let result):
                DVDReady(result: result)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Unable to Build the Disc", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Back to Videos") { dvd.startOver() }.keyboardShortcut(.defaultAction)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: burn.type, initial: true) { _, type in if let format = type.videoFormat { dvd.format = format } }
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
