import AppKit
import RippleKit
import SwiftUI

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
