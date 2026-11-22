// Ausgabegerät wechseln: Auswahl oben im Lautstärke-Tab (kein eigener Tab).

import CoreAudio
import SwiftUI

@MainActor
final class OutputDevices: ObservableObject {
    struct Device: Identifiable, Equatable { let id: AudioObjectID; let name: String }
    @Published private(set) var list: [Device] = []
    @Published private(set) var current: AudioObjectID?

    func refresh() {
        let l = outputDevices().map { Device(id: $0.id, name: $0.name) }
        if l != list { list = l }
        let c = defaultOutputDevice()
        if c != current { current = c }
    }

    func select(_ id: AudioObjectID) {
        setDefaultOutputDevice(id)  // der Listener in AppState zieht Taps und Anzeige nach
        refresh()
    }
}

struct OutputPicker: View {
    @ObservedObject var devices: OutputDevices

    var body: some View {
        Picker(selection: Binding(get: { devices.current ?? 0 }, set: { devices.select($0) })) {
            ForEach(devices.list) { Text($0.name).tag($0.id) }
        } label: {
            Image(systemName: "hifispeaker.2.fill").accessibilityLabel("Ausgabegerät")
        }
        .pickerStyle(.menu)
    }
}
