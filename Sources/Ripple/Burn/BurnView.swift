import AppKit
import RippleKit
import SwiftUI

/// Burn mode: choose a folder of MP3 or M4A files, see what fits, and burn.
struct BurnView: View {
    @Environment(BurnModel.self) private var burn
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        VStack(spacing: 0) {
            if burn.type == .video, burn.phase == .editing {
                DVDView()
            } else {
                content
            }
            if showsBar {
                Divider()
                BurnBar()
            }
        }
        .onAppear {
            burn.undoManager = undoManager
            burn.start()
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard burn.phase == .editing else { return false }
            Task { await burn.drop(urls, into: "") }
            return true
        }
    }

    private var showsBar: Bool {
        switch burn.phase {
        case .editing: !burn.items.isEmpty && burn.type != .video
        case .burning, .done, .failed: false
        }
    }

    @ViewBuilder
    private var content: some View {
        switch burn.phase {
        case .editing:
            if burn.items.isEmpty { BurnEmpty() } else { BurnEditor() }
        case .burning(let stage):
            BurningView(stage: stage)
        case .done:
            ContentUnavailableView {
                Label("Disc Ready", systemImage: "checkmark.circle")
            } description: {
                Text("The disc is finished and was ejected.")
            } actions: {
                Button("Burn Another Disc") { burn.tryAgain() }.keyboardShortcut(.defaultAction)
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Unable to Burn the Disc", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { burn.tryAgain() }.keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// Nothing chosen yet.
struct BurnEmpty: View {
    @Environment(BurnModel.self) private var burn

    var body: some View {
        VStack(spacing: 0) {
            DiscTypeHeader()
            Divider()
            ContentUnavailableView {
                Label("Choose Music Files to Burn", systemImage: "opticaldisc")
            } description: {
                Text(burn.isScanning ? "Reading files…" : "Choose a folder of MP3 or M4A files, or drop files and folders here.")
            } actions: {
                Button("Choose Folder…") { burn.chooseFolder() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(burn.isScanning)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The list, the disc type, and the capacity bar.
struct BurnEditor: View {
    @Environment(BurnModel.self) private var burn
    @State private var selection = Set<String>()
    @State private var naming: FolderNaming?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if burn.showsFolders {
                BurnFolderList(selection: $selection, naming: $naming)
            } else {
                flatList
            }
        }
        .folderNameAlert($naming, burn: burn)
    }

    private var flatList: some View {
        List(selection: $selection) {
            ForEach(Array(burn.items.enumerated()), id: \.element.id) { index, item in
                BurnRow(number: index + 1, item: item)
            }
            .onMove { burn.move(from: $0, to: $1) }
        }
        .listStyle(.plain)
        .onDeleteCommand {
            burn.remove(ids: selection)
            selection = []
        }
    }

    private var header: some View {
        @Bindable var burn = burn
        return VStack(alignment: .leading, spacing: Space.md) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(burn.volumeName).font(.title2.bold()).lineLimit(1)
                    Text(summary).font(.callout).foregroundStyle(.secondary)
                    if burn.skipped > 0 {
                        Text("\(burn.skipped) \(burn.skipped == 1 ? "file was" : "files were") skipped because \(burn.skipped == 1 ? "it is" : "they are") not MP3 or M4A.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if burn.type == .data {
                    Button("New Folder…") { naming = .create(parent: "") }
                        .help("Make a folder on the disc, then drop files into it")
                }
                Button("Choose Folder…") { burn.chooseFolder() }
                    .help("Choose a different folder of MP3 or M4A files")
            }
            Picker("Disc Type", selection: $burn.type) {
                ForEach(DiscType.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Text(burn.type.summary).font(.callout).foregroundStyle(.secondary)
            CapacityBar()
        }
        .padding(Space.margin)
        .gridArea("burn-header")
    }

    private var summary: String {
        let minutes = Int((burn.plan.totalSeconds / 60).rounded())
        return "\(burn.items.count) files · \(minutes) min"
    }
}

struct CapacityBar: View {
    @Environment(BurnModel.self) private var burn

    var body: some View {
        let over: Bool = { if case .over = burn.fit { true } else { false } }()
        let wrong: Bool = { if case .wrongMedia = burn.fit { true } else { false } }()
        VStack(alignment: .leading, spacing: Space.xs) {
            ProgressView(value: min(1, burn.plan.usedFraction(on: burn.deviceState)))
                .tint(over || wrong ? Surface.warning : nil)
                .accessibilityLabel("Disc capacity")
                .accessibilityValue(burn.plan.usedText(on: burn.deviceState))
            HStack(spacing: Space.xs) {
                Text(burn.plan.usedText(on: burn.deviceState)).monospacedDigit().foregroundStyle(.secondary)
                if let message = burn.fitMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Surface.warning)
                }
            }
            .font(.callout)
            ForEach([burn.compatibilityNote, burn.conversionNote].compactMap { $0 }, id: \.self) { note in
                Label(note, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

struct BurnRow: View {
    let number: Int
    let item: BurnItem

    var body: some View {
        HStack(spacing: Space.md) {
            Text(String(number)).monospacedDigit().foregroundStyle(.secondary).frame(width: 32, alignment: .trailing)
            Text(item.title).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(item.url.path)
            Text(item.artist).foregroundStyle(.secondary).lineLimit(1).frame(width: 160, alignment: .leading)
            Text(TrackRowView.format(item.seconds)).monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
        }
        .listRowInsets(EdgeInsets(top: Space.xs, leading: Space.margin, bottom: Space.xs, trailing: Space.margin))
        .accessibilityElement(children: .combine)
    }
}

/// The drive and disc on the left, Burn on the right.
struct BurnBar: View {
    @Environment(BurnModel.self) private var burn

    var body: some View {
        HStack(spacing: Space.md) {
            Image(systemName: burn.isReady ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(burn.isReady ? Color.secondary : Surface.warning)
            Text(burn.deviceLine).lineLimit(2)
            Spacer()
            Button(burn.type == .audio ? "Burn Audio CD" : "Burn MP3 Disc") { burn.burn() }
                .keyboardShortcut(.defaultAction)
                .disabled(!burn.canBurn)
                .help(burn.canBurn ? "Burn the files to the disc" : "Insert a blank disc and make the files fit to burn")
        }
        .padding(Space.lg)
        .gridArea("burn-bar", inset: Space.lg)
    }
}

struct BurningView: View {
    @Environment(BurnModel.self) private var burn
    let stage: BurnStage

    var body: some View {
        VStack(spacing: Space.lg) {
            Text(title).font(.title2.bold())
            ProgressView(value: fraction).frame(width: 320)
            if burn.canCancel {
                Button("Cancel") { burn.cancel() }.keyboardShortcut(.cancelAction)
                    .help("Stop before anything is written (Esc)")
            } else {
                Label("Stopping now would ruin the disc.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Surface.warning)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch stage {
        case .preparing: burn.isCancelling ? "Cancelling…" : "Preparing…"
        case .burning(let fraction): "Burning \(Int((fraction * 100).rounded()))%"
        case .finishing: "Finishing…"
        }
    }

    private var fraction: Double? {
        switch stage {
        case .preparing, .finishing: nil
        case .burning(let fraction): fraction
        }
    }
}
