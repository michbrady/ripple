import AppKit
import RippleKit
import SwiftUI

/// The menu as the disc will show it: every page, and the choices that change it.
struct DVDMenuInspector: View {
    @Environment(DVDModel.self) private var dvd
    @Environment(BurnModel.self) private var burn
    @State private var pages: [NSImage] = []
    @State private var page = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            if dvd.videos.isEmpty {
                ContentUnavailableView("No Menu Yet", systemImage: "rectangle.grid.2x2", description: Text("Add videos to see the menu."))
            } else {
                preview
                if pages.count > 1 { pager }
            }
            if !dvd.videos.isEmpty { choices }
            Spacer(minLength: 0)
        }
        .padding(Space.lg)
        .task(id: dvd.menuKey) { render() }
    }

    private var preview: some View {
        Group {
            if pages.indices.contains(page) {
                Image(nsImage: pages[page]).resizable().aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
                    .accessibilityLabel("Menu page \(page + 1) of \(pages.count): \(dvd.cleanDiscName), \(dvd.look.title) look, \(dvd.videos.count) videos")
            } else {
                Rectangle().fill(.quaternary).aspectRatio(4.0 / 3, contentMode: .fit)
            }
        }
    }

    private var choices: some View {
        @Bindable var dvd = dvd
        return VStack(alignment: .leading, spacing: Space.md) {
            Picker("Look", selection: $dvd.look) {
                ForEach(MenuLook.allCases) { Text($0.title).tag($0) }
            }
            .help("The colors of the menu")
            fileChoice("Background", name: dvd.backgroundURL?.lastPathComponent, empty: "Built-in background", problem: dvd.backgroundProblem,
                       choose: "Choose Picture\u{2026}", help: "Choose a picture for the menu's background",
                       choosing: { dvd.chooseBackground() }, remove: { dvd.removeBackground() })
            fileChoice("Music", name: dvd.musicURL?.lastPathComponent, empty: "No music", problem: dvd.musicProblem,
                       note: dvd.musicSeconds > DVDModel.maxMenuMusic ? "Plays the first 1:30, then repeats." : nil,
                       choose: "Choose Music\u{2026}", help: "Choose music to play under the menu",
                       choosing: { dvd.chooseMusic() }, remove: { dvd.removeMusic() })
        }
    }

    private func fileChoice(_ label: String, name: String?, empty: String, problem: String?, note: String? = nil, choose: String, help: String,
                            choosing: @escaping () -> Void, remove: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack {
                Text(label)
                Spacer()
                Text(name ?? empty).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            HStack {
                Button(choose, action: choosing).help(help)
                if name != nil { Button("Remove", action: remove) }
            }
            if let problem { Label(problem, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Surface.warning) }
            if let note { Label(note, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .contain)
    }

    private var pager: some View {
        HStack {
            Button("Previous Page", systemImage: "chevron.left") { page = max(0, page - 1) }
                .labelStyle(.iconOnly).disabled(page == 0)
                .help("Show the previous menu page")
            Text("Page \(page + 1) of \(pages.count)").monospacedDigit().foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
            Button("Next Page", systemImage: "chevron.right") { page = min(pages.count - 1, page + 1) }
                .labelStyle(.iconOnly).disabled(page >= pages.count - 1)
                .help("Show the next menu page")
        }
        .buttonStyle(.borderless)
        .onKeyPress(.leftArrow) { page = max(0, page - 1); return .handled }
        .onKeyPress(.rightArrow) { page = min(pages.count - 1, page + 1); return .handled }
    }

    /// Draws the pages. Nothing is converted: this is Ripple's own drawing.
    private func render() {
        let titles = dvd.items.compactMap { item -> DVDMenuTitle? in
            if case .ready(let file) = item.state { DVDMenuTitle(name: file.title, thumbnail: item.picture) } else { nil }
        }
        guard !titles.isEmpty else { pages = []; return }
        let drawn = DVDMenuRenderer.render(discName: dvd.cleanDiscName, titles: titles, standard: dvd.standard, look: dvd.look, background: dvd.backgroundImage)
        pages = drawn.compactMap { NSImage(data: $0.picture) }
        page = min(page, max(0, pages.count - 1))
    }
}
