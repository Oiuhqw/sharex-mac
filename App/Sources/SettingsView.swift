import AppKit
import KeyboardShortcuts
import ShareXCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: SettingsStore

    /// The border colour as a SwiftUI colour, stored as sRGB components.
    private var borderColor: Binding<Color> {
        Binding(
            get: { let c = store.value.options.borderColor; return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a) },
            set: { new in
                guard let c = NSColor(new).usingColorSpace(.sRGB) else { return }
                store.update { $0.options.borderColor = RGBA(Double(c.redComponent), Double(c.greenComponent),
                                                             Double(c.blueComponent), Double(c.alphaComponent)) }
            })
    }

    private func binding<T>(_ kp: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(get: { store.value[keyPath: kp] }, set: { v in store.update { $0[keyPath: kp] = v } })
    }

    var body: some View {
        TabView {
            Form {
                Picker("Delay", selection: binding(\.options.delaySeconds)) {
                    ForEach(CaptureOptions.delayChoices, id: \.self) { Text($0 == 0 ? "None" : "\($0) s").tag($0) }
                }
                Toggle("Show cursor", isOn: binding(\.options.showCursor))
                Toggle("Magnifier and crosshair", isOn: binding(\.options.showMagnifier))
                Toggle("Open annotation editor for fixed-area captures", isOn: binding(\.options.openEditor))
                Stepper("Border: \(store.value.options.borderWidth) px", value: binding(\.options.borderWidth), in: 0...20)
                ColorPicker("Border colour", selection: borderColor, supportsOpacity: true)
                    .disabled(store.value.options.borderWidth == 0)
                Toggle("Drop shadow", isOn: binding(\.options.shadow))
            }
            .tabItem { Label("Capture", systemImage: "camera.viewfinder") }

            Form {
                ForEach(Hotkeys.all.indices, id: \.self) { i in
                    KeyboardShortcuts.Recorder("\(Hotkeys.all[i].0.title):", name: Hotkeys.all[i].1)
                }
            }
            .tabItem { Label("Hotkeys", systemImage: "keyboard") }

            Form {
                Toggle("Also save PNG to folder", isOn: binding(\.saveToFile))
                TextField("Folder (empty = ~/Pictures/ShareX)", text: binding(\.saveFolder))
                if store.value.saveToFile, Export.resolveFolder(store.value.saveFolder, create: false) == nil {
                    Text("Use an absolute path to a writable folder. Failed saves offer Retry or Save As.")
                        .font(.caption).foregroundStyle(.red)
                }
                Toggle("Play sound after capture", isOn: binding(\.playSound))
                Button("Open Screen Recording settings") { Permissions.openSettings() }
            }
            .tabItem { Label("General", systemImage: "gearshape") }
        }
        .padding(20)
        .frame(width: 460)
    }
}
