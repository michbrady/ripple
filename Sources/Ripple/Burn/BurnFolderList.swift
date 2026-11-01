import RippleKit
import SwiftUI

/// Naming a folder: the alert asks for a name, then makes or renames it.
enum FolderNaming: Equatable {
    case create(parent: String)
    case rename(path: String)

    var title: String {
        switch self {
        case .create: "New Folder"
        case .rename: "Rename Folder"
        }
    }

    var button: String {
        switch self {
        case .create: "Create"
        case .rename: "Rename"
        }
    }
}

/// An MP3 Disc with folders: the top of the disc, then each folder with its files. Drag a file onto a folder to put it
/// there, or use the context menu, which also works on several files.
struct BurnFolderList: View {
    @Environment(BurnModel.self) private var burn
    @Binding var selection: Set<String>
    @Binding var naming: FolderNaming?

    var body: some View {
        List(selection: $selection) {
            ForEach(["" ] + burn.folderPaths, id: \.self) { path in
                FolderSection(path: path, naming: $naming)
            }
        }
        .listStyle(.plain)
        .onDeleteCommand {
            burn.remove(ids: selection)
            selection = []
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if !ids.isEmpty {
                Menu("Move to Folder") {
                    Button("Top Level") { burn.move(ids: ids, toFolder: "") }
                    ForEach(burn.folderPaths, id: \.self) { path in
                        Button(path.replacingOccurrences(of: "/", with: " / ")) { burn.move(ids: ids, toFolder: path) }
                    }
                }
                if ids.count == 1, let id = ids.first {
                    Button("Move Up") { burn.nudge(id: id, by: -1) }
                    Button("Move Down") { burn.nudge(id: id, by: 1) }
                }
                Divider()
                Button("Remove from List") {
                    burn.remove(ids: ids)
                    selection = []
                }
            }
        }
    }
}

private struct FolderSection: View {
    @Environment(BurnModel.self) private var burn
    let path: String
    @Binding var naming: FolderNaming?

    var body: some View {
        let files = burn.items(in: path)
        Section {
            ForEach(Array(files.enumerated()), id: \.element.id) { index, item in
                BurnRow(number: index + 1, item: item)
                    .padding(.leading, indent)
                    .draggable(item.url)
                    .folderDrop(path)
            }
            if files.isEmpty {
                Text(path.isEmpty ? "Drop files here to put them at the top of the disc." : "Drop MP3 or M4A files here.")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.leading, indent + Space.margin)
                    .selectionDisabled()
                    .folderDrop(path)
            }
        } header: {
            header(count: files.count)
                .folderDrop(path)
        }
    }

    private var indent: CGFloat { CGFloat(max(0, DiscLayout.depth(of: path)) + (path.isEmpty ? 0 : 1)) * Space.lg }

    private func header(count: Int) -> some View {
        HStack(spacing: Space.sm) {
            Image(systemName: path.isEmpty ? "opticaldisc" : "folder").foregroundStyle(.secondary)
            Text(path.isEmpty ? "Top of the disc" : DiscLayout.name(of: path)).font(.headline).lineLimit(1)
            Text("\(count) \(count == 1 ? "file" : "files")").foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.leading, CGFloat(max(0, DiscLayout.depth(of: path))) * Space.lg)
        .contentShape(Rectangle())
        .contextMenu {
            Button("New Folder…") { naming = .create(parent: path) }
            if !path.isEmpty {
                Button("Rename…") { naming = .rename(path: path) }
                Divider()
                Button("Remove Folder") { burn.removeFolder(path) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(path.isEmpty ? "Top of the disc" : DiscLayout.name(of: path)), \(count) \(count == 1 ? "file" : "files")")
    }
}

private extension View {
    /// Files dragged from Finder land in this folder. A file already in the list moves to it.
    func folderDrop(_ path: String) -> some View {
        modifier(FolderDrop(path: path))
    }
}

private struct FolderDrop: ViewModifier {
    @Environment(BurnModel.self) private var burn
    let path: String

    func body(content: Content) -> some View {
        content.dropDestination(for: URL.self) { urls, _ in
            guard burn.phase == .editing else { return false }
            Task { await burn.drop(urls, into: path) }
            return true
        }
    }
}

extension View {
    /// The name alert for creating and renaming folders.
    func folderNameAlert(_ naming: Binding<FolderNaming?>, burn: BurnModel) -> some View {
        modifier(FolderNameAlert(naming: naming, burn: burn))
    }
}

private struct FolderNameAlert: ViewModifier {
    @Binding var naming: FolderNaming?
    let burn: BurnModel
    @State private var text = ""

    func body(content: Content) -> some View {
        content
            .onChange(of: naming) { _, now in
                if case .rename(let path) = now { text = DiscLayout.name(of: path) } else { text = "" }
            }
            .alert(naming?.title ?? "", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
                TextField("Name", text: $text)
                Button(naming?.button ?? "OK") {
                    let name = text.trimmingCharacters(in: .whitespaces)
                    switch naming {
                    case .create(let parent): burn.makeFolder(named: name.isEmpty ? "Untitled Folder" : name, in: parent)
                    case .rename(let path): if !name.isEmpty { burn.renameFolder(path, to: name) }
                    case nil: break
                    }
                    naming = nil
                }
                Button("Cancel", role: .cancel) { naming = nil }
            } message: {
                Text("The folder is made on the disc. Your files on the Mac are not changed.")
            }
    }
}
