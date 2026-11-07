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
    @Environment(DVDModel.self) private var dvd

    var body: some View {
        ContentUnavailableView {
            Label("Add Videos for the Disc", systemImage: "film")
        } description: {
            Text("Drop video files here, or choose them.")
        } actions: {
            Button("Choose Videos…") { dvd.chooseVideos() }
                .keyboardShortcut(.defaultAction)
                .help("Add videos to the disc (⌘O)")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The videos on the disc, with a line of totals and anything left out.
struct DVDList: View {
    @Environment(DVDModel.self) private var dvd
    @State private var renaming: URL?

    var body: some View {
        @Bindable var dvd = dvd
        return VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    TextField("Disc Name", text: $dvd.discName)
                        .textFieldStyle(.plain).font(.title2.bold()).lineLimit(1)
                        .onChange(of: dvd.discName) { _, name in if name.count > DVDName.maxDisc { dvd.discName = String(name.prefix(DVDName.maxDisc)) } }
                        .accessibilityLabel("Disc Name")
                    Text(summary).font(.callout).foregroundStyle(.secondary)
                    if dvd.skipped > 0 {
                        Text("\(dvd.skipped) \(dvd.skipped == 1 ? "file was" : "files were") skipped because \(dvd.skipped == 1 ? "it is" : "they are") not \(dvd.skipped == 1 ? "a video" : "videos").")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if dvd.tooMany {
                        Label("A DVD holds 99 videos at most.", systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(Surface.warning)
                    }
                }
                Spacer()
                Button("Add Videos…") { dvd.chooseVideos() }
                    .help("Add videos to the disc (⌘O)")
            }
            .padding(.horizontal, Space.margin)
            .padding(.vertical, Space.md)
            Divider()
            @Bindable var dvd = dvd
            List(selection: $dvd.selection) {
                ForEach(dvd.items) { item in
                    DVDRow(item: item, renaming: $renaming)
                        .tag(item.id)
                        .contextMenu {
                            Button("Rename") { renaming = item.id }
                            Button("Move Up") { dvd.moveSelectionUp() }.disabled(!dvd.canMoveUp)
                            Button("Move Down") { dvd.moveSelectionDown() }.disabled(!dvd.canMoveDown)
                            Divider()
                            Button("Remove") { dvd.remove(ids: dvd.selection.isEmpty ? [item.id] : dvd.selection.union([item.id])) }
                        }
                }
                .onMove { dvd.move(from: $0, to: $1) }
            }
            .listStyle(.plain)
            .onDeleteCommand { dvd.remove(ids: dvd.selection) }
            .onKeyPress(.return) {
                guard dvd.selection.count == 1, let id = dvd.selection.first, dvd.title(of: id) != nil else { return .ignored }
                renaming = id
                return .handled
            }
        }
    }

    private var summary: String {
        let count = dvd.videos.count
        return "\(count) \(count == 1 ? "video" : "videos") \u{00B7} \(VideoFile.lengthText(dvd.totalSeconds))"
    }
}

struct DVDRow: View {
    @Environment(DVDModel.self) private var dvd
    let item: DVDItem
    @Binding var renaming: URL?
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Space.md) {
            picture
            VStack(alignment: .leading, spacing: 2) {
                if renaming == item.id { nameField } else {
                    Text(title).lineLimit(1).truncationMode(.tail).help(item.url.path)
                        .onTapGesture(count: 2) { if case .ready = item.state { renaming = item.id } }
                }
                detail
            }
            Spacer()
            if case .ready(let file) = item.state {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(file.lengthText).monospacedDigit()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(file.bytes), countStyle: .file)).foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
        .listRowInsets(EdgeInsets(top: Space.xs, leading: Space.margin, bottom: Space.xs, trailing: Space.margin))
        .accessibilityElement(children: .combine)
    }

    private var nameField: some View {
        TextField("Title", text: $draft)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onAppear {
                draft = title
                focused = true
            }
            .onSubmit {
                dvd.rename(item.id, to: draft)
                renaming = nil
            }
            .onExitCommand { renaming = nil }
            .accessibilityLabel("Video title")
    }

    private var title: String {
        if case .ready(let file) = item.state { return file.title }
        return item.url.deletingPathExtension().lastPathComponent
    }

    @ViewBuilder
    private var detail: some View {
        switch item.state {
        case .reading:
            HStack(spacing: Space.xs) {
                ProgressView().controlSize(.small)
                Text("Reading\u{2026}").foregroundStyle(.secondary)
            }
            .font(.callout)
        case .ready(let file):
            Text(file.isWidescreen ? "Widescreen" : "Standard screen").font(.callout).foregroundStyle(.secondary)
        case .problem(let problem):
            Label(problem.message, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Surface.warning)
        }
    }

    private var picture: some View {
        Group {
            if let image = item.picture {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "film").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary)
            }
        }
        .frame(width: 64, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

/// How full the disc is and how good the picture will be, then the drive.
struct DVDBar: View {
    @Environment(BurnModel.self) private var burn
    @Environment(DVDModel.self) private var dvd

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            if !dvd.videos.isEmpty { fit }
            if !dvd.videos.isEmpty { choices }
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
                    Label("Too long by \(DVDPlan.approximateText(seconds)). Remove a video or use a dual-layer disc.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Surface.warning)
                }
            }
            .font(.callout)
            if plan.quality == .reduced {
                Label("Reduced quality: the picture is softer to fit everything.", systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
            }
            if !isDVD { Label("Based on a single-layer DVD.", systemImage: "info.circle").font(.callout).foregroundStyle(.secondary) }
        }
    }

    private var isDVD: Bool {
        if case .ready(let media) = burn.deviceState { return media.kind == .dvd }
        return false
    }

    private func summary(_ plan: DVDPlan) -> String {
        let used = DVDPlan.approximateText(plan.totalSeconds), room = DVDPlan.approximateText(plan.longestReducedSeconds)
        if case .tooLong = plan.fit { return "\(used) of \(room)" }
        return "\(used) of \(room) \u{00B7} \(plan.quality.title)"
    }
}

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
    @State private var confirmingDiscard = false
    let result: DVDBuildResult

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
            HStack {
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
