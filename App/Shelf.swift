// Ablage: Dateien per Drag & Drop kurz in der Notch parken.
// Gemerkt werden nur Verweise auf die Originale. Dateien, die AppVol selbst erzeugt (z.B. Transkripte),
// liegen in `ShelfStore.ownDir` und werden beim Leeren gelöscht. Originale werden NIE gelöscht.

import AppKit
import SwiftUI

@MainActor
final class ShelfStore: ObservableObject {
    struct Item: Codable, Hashable { let path: String; let added: Date }

    @Published private(set) var items: [Item] = []
    static let ownDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AppVol/Shelf", isDirectory: true)
    private let d = UserDefaults.standard

    init() {
        items = (d.data(forKey: "shelf.items")).flatMap { try? JSONDecoder().decode([Item].self, from: $0) } ?? []
        // Standard: beim Systemneustart leeren
        let boot = Self.bootTime()
        if Prefs.shared.shelfClear == .restart, d.double(forKey: "shelf.boot") != boot { clear() }
        d.set(boot, forKey: "shelf.boot")
        expire()
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in Task { @MainActor in self.expire() } }
    }

    var urls: [URL] { items.map { URL(fileURLWithPath: $0.path) } }

    func add(_ urls: [URL]) {
        for u in urls where !items.contains(where: { $0.path == u.path }) { items.append(Item(path: u.path, added: Date())) }
        save()
    }

    func remove(_ url: URL) {
        items.removeAll { $0.path == url.path }
        deleteIfOwn(url)
        save()
    }

    func clear() {
        urls.forEach(deleteIfOwn)
        items = []
        save()
        // Reste eigener Dateien (z.B. nach Absturz) mit aufräumen
        try? FileManager.default.removeItem(at: Self.ownDir)
    }

    /// Intervall-Modus: Einträge, die älter als die eingestellten Stunden sind, entfernen.
    func expire() {
        guard Prefs.shared.shelfClear == .interval else { return }
        let limit = Date().addingTimeInterval(-Double(Prefs.shared.shelfHours) * 3600)
        for i in items where i.added < limit { remove(URL(fileURLWithPath: i.path)) }
    }

    private func deleteIfOwn(_ url: URL) {
        if url.standardizedFileURL.path.hasPrefix(Self.ownDir.standardizedFileURL.path) { try? FileManager.default.removeItem(at: url) }
    }

    private func save() { d.set(try? JSONEncoder().encode(items), forKey: "shelf.items") }

    static func bootTime() -> Double {
        var tv = timeval(); var size = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &tv, &size, nil, 0)
        return Double(tv.tv_sec)
    }
}

struct ShelfView: View {
    @ObservedObject var store: ShelfStore

    var body: some View {
        if store.items.isEmpty {
            VStack {
                Image(systemName: "tray.and.arrow.down").font(.title)
                Text("Dateien hierher ziehen")
            }
            .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading) {
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(store.urls, id: \.self) { url in
                            VStack(spacing: 4) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 44, height: 44)
                                Text(url.lastPathComponent).font(.caption).lineLimit(2).multilineTextAlignment(.center).frame(width: 72)
                            }
                            .onDrag { NSItemProvider(object: url as NSURL) }
                            .contextMenu {
                                Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                Button("Aus Ablage entfernen") { store.remove(url) }
                            }
                            .help(url.path)
                        }
                    }
                }
                Button("Ablage leeren") { store.clear() }.font(.caption)
            }
        }
    }
}

struct ShelfSettings: View {
    @ObservedObject var prefs = Prefs.shared

    var body: some View {
        Picker("Ablage leeren", selection: $prefs.shelfClear) {
            Text("Beim Systemneustart").tag(Prefs.ShelfClear.restart)
            Text("Nach Zeitintervall").tag(Prefs.ShelfClear.interval)
        }
        if prefs.shelfClear == .interval {
            Stepper("Einträge entfernen nach \(prefs.shelfHours) h", value: $prefs.shelfHours, in: 1...72)
        }
        Text("Gelöscht werden nur Einträge der Ablage und Dateien, die AppVol selbst erzeugt hat. Deine Originaldateien bleiben immer erhalten.")
            .font(.caption).foregroundStyle(.secondary)
    }
}
