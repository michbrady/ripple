import RippleKit
import SwiftUI

/// The Settings window (Command-Comma). One tab per topic, at most about
/// six. Each tab is a grouped Form that sizes to its content, so the
/// window grows to fit and shows no scroll bar it does not need.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsTab) {
            ForEach(SettingsTab.allCases) { tab in
                page(tab)
                    .tabItem { Label(tab.title, systemImage: tab.symbol) }
                    .tag(tab)
            }
        }
        .noInitialFocus()
    }

    @ViewBuilder
    private func page(_ tab: SettingsTab) -> some View {
        Form {
            switch tab {
            case .general: GeneralSettings()
            case .appearance: AppearanceSettings()
            }
        }
        .formStyle(.grouped)
        .fitsContent()
        .frame(width: 520)
    }
}

/// The Settings tabs. Snapshot mode walks through every case.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, appearance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintpalette"
        }
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section("Rip") {
            LabeledContent("Output Folder") {
                HStack {
                    Text(model.outputFolder.lastPathComponent).lineLimit(1).help(model.outputFolder.path)
                    Button("Change…") { model.chooseFolder() }
                }
            }
            Picker("Format", selection: $model.format) {
                ForEach(RipFormat.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("MP3 Quality", selection: $model.mp3Quality) {
                ForEach(MP3Encoder.choices, id: \.self) { Text($0.label).tag($0) }
            }
            .disabled(model.format != .mp3)
            Text("M4A files use AAC at 256 kbps.").font(.callout).foregroundStyle(.secondary)
        }
        Section("Disc") {
            Toggle("Eject when done", isOn: $model.ejectWhenDone)
            Text("Ejects the disc after a rip with no problems. A disc with tracks that need attention stays in.")
                .font(.callout).foregroundStyle(.secondary)
            Toggle("Start when a disc matches", isOn: $model.startOnMatch)
            Text("Starts ripping as soon as the album is found. Waits if there is no match or more than one.")
                .font(.callout).foregroundStyle(.secondary)
            Toggle("Check for errors", isOn: $model.verifyReads)
            Text("Reads each part of the disc again to make sure the two reads agree. Slower, but it catches bad data on scratched discs.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}
