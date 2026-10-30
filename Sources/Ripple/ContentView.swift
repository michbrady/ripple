import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            content
            if model.hasDisc, !isFailed {
                Divider()
                BottomBar()
            }
        }
        .navigationTitle(model.windowTitle)
        .toolbar {
            ToolbarItem {
                Button("Eject", systemImage: "eject") { model.eject() }
                    .help("Eject the disc (⌘E)")
                    .disabled(!model.hasDisc && !isFailed)
            }
        }
        .task {
            model.start()
            SelfTest.runIfRequested(model: model)
            Snapshot.runIfRequested(model: model, openSettings: openSettings)
        }
    }

    private var isFailed: Bool {
        if case .failed = model.phase { return true }
        return false
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .empty:
            ContentUnavailableView(
                "Insert a Disc",
                systemImage: "opticaldisc",
                description: Text("Ripple reads audio discs from a built-in or USB drive.")
            )
        case .reading:
            VStack(spacing: Space.md) {
                ProgressView()
                Text("Reading Disc…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label(message, systemImage: "exclamationmark.triangle")
            } actions: {
                Button("Eject") { model.eject() }
            }
        case .ready, .ripping, .done:
            VStack(spacing: 0) {
                AlbumHeader()
                Divider()
                TrackList()
            }
        }
    }
}

/// Album, artist, and Cover above the track list.
struct AlbumHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Space.lg) {
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .fill(.quaternary)
                .frame(width: 96, height: 96)
                .overlay { Image(systemName: "opticaldisc").font(.largeTitle).foregroundStyle(.secondary) }
                .accessibilityLabel("Cover")
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(model.albumTitle).font(.title2.bold()).lineLimit(1)
                Text(model.albumArtist).foregroundStyle(.secondary).lineLimit(1)
                Text(summary).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(Space.margin)
        .gridArea("album-header")
    }

    private var summary: String {
        let minutes = Int((model.totalSeconds / 60).rounded())
        return "\(model.rows.count) tracks · \(minutes) min"
    }
}

/// The tracks, with a checkbox, number, title, artist, length, and status.
struct TrackList: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Int?

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            header
            List(selection: $selection) {
                ForEach($model.rows) { $row in
                    TrackRowView(row: $row, locked: model.isRipping, showsArtist: showsArtist)
                        .tag(row.id)
                        .listRowInsets(EdgeInsets(top: Space.xs, leading: Space.margin, bottom: Space.xs, trailing: Space.margin))
                }
            }
            .listStyle(.plain)
            .onKeyPress(.space) {
                guard !model.isRipping, let id = selection, let index = model.rows.firstIndex(where: { $0.id == id }) else { return .ignored }
                model.rows[index].include.toggle()
                return .handled
            }
        }
    }

    /// The Artist column appears once a lookup or an edit gives any track an artist.
    private var showsArtist: Bool { model.rows.contains { !$0.artist.isEmpty } }

    private var header: some View {
        HStack(spacing: Space.md) {
            Spacer().frame(width: 20)
            Text("#").frame(width: 32, alignment: .trailing)
            Text("Title").frame(maxWidth: .infinity, alignment: .leading)
            if showsArtist { Text("Artist").frame(width: 160, alignment: .leading) }
            Text("Length").frame(width: 64, alignment: .trailing)
            Spacer().frame(width: 96)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Space.margin)
        .padding(.vertical, Space.sm)
    }
}

struct TrackRowView: View {
    @Binding var row: TrackRow
    let locked: Bool
    let showsArtist: Bool

    var body: some View {
        HStack(spacing: Space.md) {
            Toggle("Include \(row.title)", isOn: $row.include)
                .labelsHidden()
                .disabled(locked)
                .frame(width: 20)
            Text(String(row.number)).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)
            Text(row.title).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(row.title)
            if showsArtist {
                Text(row.artist).foregroundStyle(.secondary).lineLimit(1)
                    .frame(width: 160, alignment: .leading)
            }
            Text(Self.format(row.seconds)).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
            status.frame(width: 96, height: Space.xl, alignment: .leading)
        }
        .opacity(row.include ? 1 : 0.5)
        .accessibilityElement(children: .combine)
        .accessibilityValue(row.include ? "included" : "not included")
    }

    @ViewBuilder
    private var status: some View {
        switch row.status {
        case .waiting:
            Text("")
        case .ripping(let fraction):
            ProgressView(value: fraction).accessibilityLabel("Ripping \(row.title)")
        case .done:
            Label("Done", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
        }
    }

    static func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }
}

/// Output Folder on the left, the main action on the right.
struct BottomBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Space.md) {
            Text("Output Folder:").foregroundStyle(.secondary)
            Text(model.outputFolder.lastPathComponent).lineLimit(1)
                .help(model.outputFolder.path)
            Button("Change…") { model.chooseFolder() }
                .disabled(model.isRipping)
                .help("Choose where ripped albums are saved")
            Spacer()
            action
        }
        .padding(Space.lg)
        .gridArea("bottom-bar", inset: Space.lg)
    }

    @ViewBuilder
    private var action: some View {
        switch model.phase {
        case .ripping:
            Text(model.isCancelling ? "Cancelling…" : progressText).foregroundStyle(.secondary).monospacedDigit()
            ProgressView(value: totalFraction).frame(width: 160)
            Button("Cancel") { model.cancel() }
                .keyboardShortcut(.cancelAction)
                .disabled(model.isCancelling)
                .help("Stop ripping. Finished tracks are kept (Esc)")
        case .done(let folder):
            Text("Ripped \(model.rows.filter { $0.status == .done }.count) Tracks").foregroundStyle(.secondary)
            Button("Show in Finder") {
                if let folder { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
            }
            Button("Rip Another Disc") { model.rippedAnother() }
                .keyboardShortcut(.defaultAction)
        default:
            if model.checkedCount == 0 {
                Text("Check at least one track.").foregroundStyle(.secondary)
            }
            Button(model.checkedCount == 1 ? "Rip 1 Track" : "Rip \(model.checkedCount) Tracks") { model.rip() }
                .keyboardShortcut(.defaultAction)
                .disabled(model.checkedCount == 0)
                .help("Rip the checked tracks to the Output Folder (⌘R)")
        }
    }

    private var checked: [TrackRow] { model.rows.filter(\.include) }

    private var totalFraction: Double {
        guard !checked.isEmpty else { return 0 }
        let sum = checked.reduce(0.0) { total, row in
            switch row.status {
            case .waiting: total
            case .ripping(let fraction): total + fraction
            case .done: total + 1
            }
        }
        return sum / Double(checked.count)
    }

    private var progressText: String {
        let done = checked.filter { $0.status == .done }.count
        let current = checked.first { if case .ripping = $0.status { true } else { false } }
        let position = min(done + 1, checked.count)
        return "Ripping \(position) of \(checked.count)" + (current.map { " · \($0.title)" } ?? "")
    }
}
