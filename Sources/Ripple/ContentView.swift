import AppKit
import RippleKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(BurnModel.self) private var burn
    @Environment(DVDModel.self) private var dvd
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var model = model
        return Group {
            if model.mode == .burn {
                BurnView()
            } else {
                VStack(spacing: 0) {
                    content
                    if model.hasDisc, !isFailed {
                        Divider()
                        BottomBar()
                    }
                }
            }
        }
        .navigationTitle(model.mode == .burn ? burn.windowTitle : model.windowTitle)
        .sheet(isPresented: $model.isPickingMatch) { MatchPicker() }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Mode", selection: $model.mode) {
                    ForEach(AppMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .disabled(model.isBusy || burn.isBusy)
                .help("Switch between ripping a disc and burning one")
            }
            ToolbarItem {
                if model.mode == .burn, burn.type == .video {
                    @Bindable var dvd = dvd
                    Toggle("Menu", systemImage: "rectangle.grid.2x2", isOn: $dvd.showsMenu)
                        .help("Show the menu preview and choices (⌥⌘M)")
                        .keyboardShortcut("m", modifiers: [.command, .option])
                }
            }
            ToolbarItem {
                if model.mode == .burn {
                    Button("Eject", systemImage: "eject") { burn.eject() }
                        .help("Eject the disc (⌘E)")
                        .disabled(burn.isBusy || burn.deviceState == .noDisc || burn.deviceState == .noDrive)
                } else {
                    Button("Eject", systemImage: "eject") { model.eject() }
                        .help("Eject the disc (⌘E)")
                        .disabled(!model.hasDisc && !isFailed)
                }
            }
        }
        .task {
            model.start()
            burn.start()
            SelfTest.runIfRequested(model: model, burn: burn, dvd: dvd)
            Snapshot.runIfRequested(model: model, burn: burn, dvd: dvd, openSettings: openSettings)
            // The installer is still open after a drag install: offer to eject it and trash the .dmg.
            if !Store.isOverridden {
                try? await Task.sleep(for: .seconds(1.5))
                await InstallerCleanup().offer()
            }
        }
    }

    private func failureButton(_ action: RipFailure.Action) -> String {
        switch action {
        case .tryAgain: "Try Again"
        case .chooseFolder: "Choose Folder…"
        case .eject: "Eject"
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
        case .failed(let failure):
            ContentUnavailableView {
                Label(failure.message, systemImage: "exclamationmark.triangle")
            } actions: {
                Button(failureButton(failure.action)) { model.performFailureAction() }
                    .keyboardShortcut(.defaultAction)
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

/// Album, artist, and Cover above the track list. Album and artist are fields.
struct AlbumHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Space.lg) {
            CoverView()
            VStack(alignment: .leading, spacing: Space.xs) {
                TextField("Album", text: Binding(get: { model.albumTitle }, set: model.setAlbumTitle),
                          prompt: Text("Unknown Album"))
                    .textFieldStyle(.plain)
                    .font(.title2.bold())
                TextField("Artist", text: Binding(get: { model.albumArtist }, set: model.setAlbumArtist),
                          prompt: Text("Unknown Artist"))
                    .textFieldStyle(.plain)
                    .foregroundStyle(.secondary)
                Text(summary).font(.callout).foregroundStyle(.secondary)
                lookupStatus
            }
            Spacer()
            if model.matches.count > 1 || model.lookupState == .possible {
                Button("Choose Album…") { model.isPickingMatch = true }
                    .disabled(model.isRipping)
                    .help("Pick another album that matches this disc")
            }
        }
        .padding(Space.margin)
        .gridArea("album-header")
    }

    private var summary: String {
        let minutes = Int((model.totalSeconds / 60).rounded())
        let year = model.albumYear.isEmpty ? "" : "\(model.albumYear) · "
        let disc = model.discCount > 1 ? "Disc \(model.discNumber) of \(model.discCount) · " : ""
        return "\(year)\(disc)\(model.rows.count) tracks · \(minutes) min"
    }

    @ViewBuilder
    private var lookupStatus: some View {
        switch model.lookupState {
        case .searching:
            HStack(spacing: Space.sm) {
                ProgressView().controlSize(.small)
                Text("Looking up album…")
            }
            .font(.callout).foregroundStyle(.secondary)
        case .possible:
            Text("No exact match for this disc. \(model.matches.count) possible \(model.matches.count == 1 ? "album" : "albums"): choose one, or enter the details yourself.")
                .font(.callout).foregroundStyle(Surface.warning)
        case .notFound:
            Text("No match found. Enter the details yourself.").font(.callout).foregroundStyle(.secondary)
        case .offline:
            Text("Unable to look up this disc. Enter the details yourself.").font(.callout).foregroundStyle(.secondary)
        case .found:
            if model.matchConfidence == .byLength {
                Text("Not an exact disc match. Every track length fits, so this is almost certainly the album.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        case .idle:
            EmptyView()
        }
    }
}

/// The Cover: the album's picture, or a placeholder. Drop an image file on it to use your own.
struct CoverView: View {
    @Environment(AppModel.self) private var model
    @State private var isTargeted = false

    var body: some View {
        RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
            .fill(.quaternary)
            .frame(width: 96, height: 96)
            .overlay {
                if let image = model.coverImage {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "opticaldisc").font(.largeTitle).foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).strokeBorder(.tint, lineWidth: 2)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                return model.setCover(from: url)
            } isTargeted: { isTargeted = $0 }
            .help("Drop an image here to use it as the Cover")
            .accessibilityLabel("Cover")
    }
}

/// Sheet: pick which album matches the disc.
struct MatchPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Text("Choose Album").font(.headline)
            List(model.matches, selection: $selection) { match in
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(match.title).lineLimit(1)
                    Text("\(match.artist) · \(match.detail)").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                .tag(match.id)
                .padding(.vertical, Space.xs)
            }
            .frame(height: 240)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Choose") {
                    if let selection { model.chooseMatch(id: selection) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
        }
        .padding(Space.margin)
        .frame(width: 480)
        .noInitialFocus()
        .onAppear { selection = model.selectedMatchID }
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

    private var showsArtist: Bool { true }

    private var header: some View {
        HStack(spacing: Space.md) {
            Spacer().frame(width: 20)
            Text("#").frame(width: 32, alignment: .trailing)
            Text("Title").frame(maxWidth: .infinity, alignment: .leading)
            if showsArtist { Text("Artist").frame(width: 160, alignment: .leading) }
            Text("Length").frame(width: 64, alignment: .trailing)
            Spacer().frame(width: 144)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        // The list insets its rows a little more than listRowInsets says.
        .padding(.horizontal, Space.margin + Space.sm)
        .padding(.vertical, Space.sm)
    }
}

struct TrackRowView: View {
    @Binding var row: TrackRow
    let locked: Bool
    let showsArtist: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Space.md) {
            Toggle("Include \(row.title)", isOn: $row.include)
                .labelsHidden()
                .disabled(locked)
                .frame(width: 20)
            Text(String(row.number)).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)
            TextField("Title", text: Binding(get: { row.title }, set: { model.setTitle($0, row: row.id) }))
                .textFieldStyle(.plain)
                .disabled(locked)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(row.title)
            if showsArtist {
                TextField("Artist", text: Binding(get: { row.artist }, set: { model.setArtist($0, row: row.id) }),
                          prompt: Text("Artist"))
                    .textFieldStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(locked)
                    .frame(width: 160, alignment: .leading)
            }
            Text(Self.format(row.seconds)).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
            status.frame(width: 144, height: Space.xl, alignment: .leading)
        }
        .opacity(row.include ? 1 : 0.5)
        .accessibilityElement(children: .contain)
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
        case .needsAttention(let unreadable, let suspect):
            HStack(spacing: Space.xs) {
                Label("Needs Attention", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Surface.warning)
                    .help(attentionHelp(unreadable: unreadable, suspect: suspect))
                Button("Retry", systemImage: "arrow.clockwise") { model.retry(row.id) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(model.isRipping || model.isDiscEjected)
                    .help(model.isDiscEjected ? "Insert the disc to rip this track again" : "Rip this track again")
            }
        }
    }

    private func attentionHelp(unreadable: Int, suspect: Int) -> String {
        var parts: [String] = []
        if unreadable > 0 { parts.append("\(unreadable) unreadable \(unreadable == 1 ? "spot" : "spots") became silence") }
        if suspect > 0 { parts.append("\(suspect) \(suspect == 1 ? "spot" : "spots") may have errors") }
        return parts.joined(separator: ", ") + ". Clean the disc and rip this track again."
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
        @Bindable var model = model
        return HStack(spacing: Space.md) {
            Text("Output Folder:").foregroundStyle(.secondary)
            Text(model.outputFolder.lastPathComponent).lineLimit(1)
                .help(model.outputFolder.path)
            Button("Change…") { model.chooseFolder() }
                .disabled(model.isRipping)
                .help("Choose where ripped albums are saved")
            Picker("Format", selection: $model.format) {
                ForEach(RipFormat.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .disabled(model.isRipping)
            .help("Choose MP3 or M4A for the ripped files")
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
            Text("Ripped \(model.rippedCount) Tracks").foregroundStyle(.secondary)
            if model.isDiscEjected { Text("Disc ejected").foregroundStyle(.secondary) }
            if model.needsAttentionCount > 0 {
                Label("\(model.needsAttentionCount) Need Attention", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Surface.warning)
            }
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
            case .done, .needsAttention: total + 1
            }
        }
        return sum / Double(checked.count)
    }

    private var progressText: String {
        let done = checked.filter { if case .ripping = $0.status { false } else if case .waiting = $0.status { false } else { true } }.count
        let current = checked.first { if case .ripping = $0.status { true } else { false } }
        let position = min(done + 1, checked.count)
        return "Ripping \(position) of \(checked.count)" + (current.map { " · \($0.title)" } ?? "")
    }
}
