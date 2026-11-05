import AppKit
import KeyboardShortcuts
import ShareXCore
import SwiftUI

@MainActor
struct SettingsView: View {
    private enum Page: String, CaseIterable, Identifiable {
        case capture = "Capture", shortcuts = "Shortcuts", output = "Output"
        var id: String { rawValue.lowercased() }
        var symbol: String {
            switch self {
            case .capture: "camera.viewfinder"
            case .shortcuts: "keyboard"
            case .output: "square.and.arrow.down"
            }
        }
        var detail: String {
            switch self {
            case .capture: "Set up the capture and annotation editor."
            case .shortcuts: "Start a capture from any app. Click a shortcut to change it."
            case .output: "Copy each capture to the clipboard and save a local PNG."
            }
        }
    }

    @ObservedObject var store: SettingsStore
    @StateObject private var shortcuts = Hotkeys.Editor()
    @State private var page: Page? = .capture
    @State private var search = ""
    @State private var confirmRestoreShortcuts = false

    private var borderColor: Binding<Color> {
        Binding(
            get: {
                let c = store.value.options.borderColor
                return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
            },
            set: { color in
                guard let c = NSColor(color).usingColorSpace(.sRGB) else { return }
                store.update {
                    $0.options.borderColor = RGBA(Double(c.redComponent), Double(c.greenComponent),
                                                 Double(c.blueComponent), Double(c.alphaComponent))
                }
            })
    }

    private func binding<T>(_ key: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(get: { store.value[keyPath: key] }, set: { value in store.update { $0[keyPath: key] = value } })
    }

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $page) { item in
                Label(item.rawValue, systemImage: item.symbol)
                    .padding(.vertical, 5)
                    .tag(item)
                    .accessibilityIdentifier("settings.page.\(item.id)")
            }
            .listStyle(.sidebar)
            .navigationTitle("Settings")
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 210)
            .safeAreaInset(edge: .bottom) {
                Label("ShareX", systemImage: "camera.viewfinder")
                    .font(.headline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(18)
            }
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text((page ?? .capture).rawValue).font(.title).fontWeight(.semibold)
                    Text((page ?? .capture).detail).foregroundStyle(.secondary)
                }
                .padding(24)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("settings.heading")
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        switch page ?? .capture {
                        case .capture: capturePage
                        case .shortcuts: shortcutsPage
                        case .output: outputPage
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                Label("Changes are saved automatically.", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 24).padding(.vertical, 12)
                    .accessibilityIdentifier("settings.saved")
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 700, minHeight: 520)
        .alert("Restore all shortcut defaults?", isPresented: $confirmRestoreShortcuts) {
            Button("Cancel", role: .cancel) {}
            Button("Restore Defaults", role: .destructive) { shortcuts.restoreAll() }
                .accessibilityIdentifier("settings.shortcuts.confirmRestore")
        } message: {
            Text("This resets all eight commands. Region uses Control-Shift-1. The other seven commands become unassigned.")
        }
    }

    private var capturePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection("Before capture") {
                Picker("Capture delay", selection: binding(\.options.delaySeconds)) {
                    ForEach(Array(Set(CaptureOptions.delayChoices + [store.value.options.delaySeconds])).sorted(), id: \.self) {
                        Text($0 == 0 ? "No delay" : "\($0) seconds").tag($0)
                    }
                }
                .accessibilityIdentifier("settings.capture.delay")
                Toggle("Include the pointer in screenshots", isOn: binding(\.options.showCursor))
                    .accessibilityIdentifier("settings.capture.cursor")
            }
            SettingsSection("Selection and editing") {
                Toggle("Show magnifier and crosshair", isOn: binding(\.options.showMagnifier))
                    .accessibilityIdentifier("settings.capture.magnifier")
                Text("Inspect pixels while you select or adjust an area.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Toggle("Open the editor for fixed-area captures", isOn: binding(\.options.openEditor))
                    .accessibilityIdentifier("settings.capture.editor")
                Text("Review fullscreen, active window, active monitor, and last-region captures before export.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SettingsSection("Appearance") {
                Stepper("Border width: \(store.value.options.borderWidth) pt",
                        value: binding(\.options.borderWidth), in: 0...CaptureOptions.maxBorderWidth)
                    .accessibilityIdentifier("settings.capture.borderWidth")
                ColorPicker("Border color", selection: borderColor, supportsOpacity: true)
                    .disabled(store.value.options.borderWidth == 0)
                    .accessibilityIdentifier("settings.capture.borderColor")
                Toggle("Add a drop shadow", isOn: binding(\.options.shadow))
                    .accessibilityIdentifier("settings.capture.shadow")
            }
            HStack {
                Button("Restore Capture Defaults") { store.update { $0.options = CaptureOptions() } }
                    .accessibilityIdentifier("settings.capture.restore")
                Spacer()
                Button("Screen Recording Permission…") { Permissions.openSettings() }
                    .accessibilityIdentifier("settings.capture.permission")
            }
            .controlSize(.small)
        }
    }

    private var matchingCommands: [Hotkeys.Command] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return Hotkeys.commands.filter {
            query.isEmpty || $0.title.localizedStandardContains(query) || $0.detail.localizedStandardContains(query)
        }
    }

    private var shortcutsPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("Search shortcuts", text: $search)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search shortcuts")
                .accessibilityIdentifier("settings.shortcuts.search")
            Text("Press your key combination, then release it. Press Esc to cancel.")
                .font(.caption).foregroundStyle(.secondary)
            if matchingCommands.isEmpty {
                ContentUnavailableView.search(text: search)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("settings.shortcuts.empty")
            } else {
                VStack(spacing: 0) {
                    ForEach(matchingCommands) { command in
                        shortcutRow(command)
                        if command.id != matchingCommands.last?.id { Divider().padding(.horizontal, 14) }
                    }
                }
                .background(.background, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
            }
            if let feedback = shortcuts.feedback {
                Label(feedback.text, systemImage: feedback.isConflict ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(feedback.isConflict ? Color.orange : Color.secondary)
                    .accessibilityIdentifier("settings.shortcuts.feedback")
            }
            HStack {
                Text("\(matchingCommands.count) of \(Hotkeys.commands.count) commands")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Restore All Defaults…") { confirmRestoreShortcuts = true }
                    .accessibilityIdentifier("settings.shortcuts.restoreAll")
            }
        }
    }

    private func shortcutRow(_ command: Hotkeys.Command) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(command.title).fontWeight(.medium)
                Text(command.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ShortcutRecorder(command: command, editor: shortcuts)
                .frame(width: 136)
            Menu {
                Button("Clear Shortcut") { shortcuts.clear(command) }
                    .accessibilityIdentifier("settings.shortcut.\(command.id).clear")
                Button("Restore Default") { shortcuts.restore(command) }
                    .accessibilityIdentifier("settings.shortcut.\(command.id).restore")
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
            .accessibilityLabel("Options for \(command.title) shortcut")
            .accessibilityIdentifier("settings.shortcut.\(command.id).options")
        }
        .padding(14)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.shortcut.\(command.id)")
    }

    private var outputPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection("Clipboard") {
                Label("Every completed capture is copied to the clipboard.", systemImage: "doc.on.clipboard")
                Text("Paste the image into another app with Command-V.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SettingsSection("Local PNG files") {
                Toggle("Save each capture to a folder", isOn: binding(\.saveToFile))
                    .accessibilityIdentifier("settings.output.saveToFile")
                Divider()
                Text("Save folder").fontWeight(.medium)
                Text(Export.resolveFolder(store.value.saveFolder, create: false)?.path ?? store.value.saveFolder)
                    .font(.callout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Save folder")
                    .accessibilityIdentifier("settings.output.folder")
                HStack {
                    Button("Choose Folder…", action: chooseFolder)
                        .accessibilityIdentifier("settings.output.chooseFolder")
                    Button("Use Default Folder") { store.update { $0.saveFolder = "" } }
                        .disabled(store.value.saveFolder.isEmpty)
                        .accessibilityIdentifier("settings.output.defaultFolder")
                }
                Label(folderStatus.text, systemImage: folderStatus.symbol)
                    .font(.caption)
                    .foregroundStyle(folderStatus.isError ? Color.orange : Color.secondary)
                    .accessibilityIdentifier("settings.output.folderStatus")
            }
            SettingsSection("After capture") {
                Toggle("Play a sound after capture", isOn: binding(\.playSound))
                    .accessibilityIdentifier("settings.output.sound")
            }
        }
    }

    private var folderStatus: (text: String, symbol: String, isError: Bool) {
        guard store.value.saveToFile else { return ("PNG saving is off. Captures still go to the clipboard.", "clipboard", false) }
        guard let folder = Export.resolveFolder(store.value.saveFolder, create: false) else {
            return ("This folder is not writable. Choose another folder. Failed saves offer Retry or Save As.", "exclamationmark.triangle", true)
        }
        if FileManager.default.fileExists(atPath: folder.path) {
            return ("PNG files are saved here after each capture.", "checkmark.circle", false)
        }
        var parent = folder.deletingLastPathComponent()
        while parent.path != "/" && !FileManager.default.fileExists(atPath: parent.path) { parent.deleteLastPathComponent() }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory),
              isDirectory.boolValue, FileManager.default.isWritableFile(atPath: parent.path) else {
            return ("This folder cannot be created. Choose another folder.", "exclamationmark.triangle", true)
        }
        return ("This folder will be created on the first save.", "folder.badge.plus", false)
    }

    private func chooseFolder() {
        guard let window = NSApp.keyWindow else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a screenshot folder"
        panel.prompt = "Choose Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = Export.resolveFolder(store.value.saveFolder, create: false)
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let folder = panel.url else { return }
            store.update { $0.saveFolder = folder.path }
        }
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
    }
}

@MainActor
private struct ShortcutRecorder: NSViewRepresentable {
    let command: Hotkeys.Command
    let editor: Hotkeys.Editor

    func makeNSView(context: Context) -> KeyboardShortcuts.RecorderCocoa {
        let recorder = KeyboardShortcuts.RecorderCocoa(for: command.name) { editor.recorded($0, for: command) }
        recorder.validateShortcut = { editor.validate($0, for: command) }
        recorder.setAccessibilityLabel("\(command.title) shortcut")
        recorder.setAccessibilityHelp(command.detail)
        recorder.setAccessibilityIdentifier("settings.shortcut.\(command.id).recorder")
        return recorder
    }

    func updateNSView(_ recorder: KeyboardShortcuts.RecorderCocoa, context: Context) {}
}
