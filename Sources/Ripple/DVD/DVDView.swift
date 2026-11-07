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
            if dvd.items.isEmpty { DVDEmpty() } else { DVDList() }
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

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: Space.xs) {
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
            List(dvd.items) { DVDRow(item: $0) }
                .listStyle(.plain)
        }
    }

    private var summary: String {
        let count = dvd.videos.count
        return "\(count) \(count == 1 ? "video" : "videos") \u{00B7} \(VideoFile.lengthText(dvd.totalSeconds))"
    }
}

struct DVDRow: View {
    let item: DVDItem

    var body: some View {
        HStack(spacing: Space.md) {
            picture
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1).truncationMode(.tail).help(item.url.path)
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
