// AppVol Notch: Lautstärke pro App, Kurzablage per Drag & Drop und Schalter – in der Notch und in der Menüleiste.

import AppKit
import CoreAudio
import SwiftUI
import UniformTypeIdentifiers

// ---------- Zustand ----------

struct AppRow: Identifiable {
    let id: String          // Gruppen-Schlüssel (Bundle-ID der App)
    let name: String
    let icon: NSImage?
    let symbol: String      // SF Symbol, wenn kein App-Icon
    let processes: [AudioObjectID]
    let playing: Bool
}

@MainActor
final class AppState: ObservableObject {
    enum Tab: String, CaseIterable { case volume = "Lautstärke", shelf = "Ablage", switches = "Schalter" }

    @Published var expanded = false
    @Published var tab: Tab = .volume
    @Published var rows: [AppRow] = []
    @Published var levels: [String: Float] = [:]
    @Published var shelf: [URL] = []
    @Published var error: String?
    @Published var safariUntil: Date?
    @Published var system: Float?   // Gesamtlautstärke, nil = nicht regelbar

    private var taps: [String: VolumeTap] = [:]
    let safariFlag = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("mcp/safari/.enabled_until")
    var hasSafariMCP: Bool { FileManager.default.fileExists(atPath: safariFlag.deletingLastPathComponent().path) }

    init() {
        refresh()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in Task { @MainActor in self.refresh() } }
    }

    func refresh() {
        var groups: [String: (name: String, icon: NSImage?, symbol: String, ids: [AudioObjectID], playing: Bool)] = [:]
        let apps = NSWorkspace.shared.runningApplications
        for p in audioProcesses() {
            let (key, name, icon, symbol) = describe(p, apps)
            guard p.playing || taps[key] != nil else { continue }
            var g = groups[key] ?? (name, icon, symbol, [], false)
            g.ids.append(p.id)
            g.playing = g.playing || p.playing
            groups[key] = g
        }
        rows = groups.map { AppRow(id: $0.key, name: $0.value.name, icon: $0.value.icon, symbol: $0.value.symbol, processes: $0.value.ids, playing: $0.value.playing) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        system = systemVolume()
        if let t = try? String(contentsOf: safariFlag, encoding: .utf8), let v = Double(t.trimmingCharacters(in: .whitespacesAndNewlines)), v > Date().timeIntervalSince1970 {
            safariUntil = Date(timeIntervalSince1970: v)
        } else { safariUntil = nil }
    }

    /// Ordnet Hilfsprozesse (z.B. com.google.Chrome.helper) ihrer App zu.
    private func describe(_ p: AudioProcess, _ apps: [NSRunningApplication]) -> (String, String, NSImage?, String) {
        switch p.bundle {
        case "com.apple.avconferenced": return (p.bundle, "Anrufe (FaceTime/iPhone)", nil, "phone.fill")
        case "com.apple.WebKit.GPU":
            return (p.bundle, "Safari / Web", apps.first { $0.bundleIdentifier == "com.apple.Safari" }?.icon, "safari")
        default: break
        }
        let owner = apps.filter { $0.bundleIdentifier.map { p.bundle == $0 || p.bundle.hasPrefix($0 + ".") } ?? false }
            .max { ($0.bundleIdentifier?.count ?? 0) < ($1.bundleIdentifier?.count ?? 0) }
            ?? NSRunningApplication(processIdentifier: p.pid)
        let key = owner?.bundleIdentifier ?? p.bundle
        return (key, owner?.localizedName ?? p.bundle, owner?.icon, "speaker.wave.2")
    }

    func level(_ key: String) -> Float { levels[key] ?? 1 }

    func setSystem(_ v: Float) {
        setSystemVolume(v)
        system = v
    }

    func setLevel(_ row: AppRow, _ value: Float) {
        let v = abs(value - 1) < 0.03 ? 1 : value  // rastet bei 100 % ein = Originalton
        levels[row.id] = v
        if v == 1 { taps.removeValue(forKey: row.id)?.stop(); return }
        if let t = taps[row.id] { t.volume = v; return }
        do { taps[row.id] = try VolumeTap(processes: row.processes, volume: v); error = nil }
        catch { self.error = "\(error)"; levels[row.id] = 1 }
    }

    func resetAll() {
        taps.values.forEach { $0.stop() }
        taps = [:]; levels = [:]
        refresh()
    }

    func addToShelf(_ urls: [URL]) {
        for u in urls where !shelf.contains(u) { shelf.append(u) }
        tab = .shelf
    }

    func setSafari(minutes: Double?) {
        let until = minutes.map { Date().timeIntervalSince1970 + $0 * 60 } ?? 0
        try? String(until).write(to: safariFlag, atomically: true, encoding: .utf8)
        refresh()
    }
}

// ---------- Oberfläche ----------

struct PanelContent: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $state.tab) {
                ForEach(AppState.Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()

            switch state.tab {
            case .volume: volume
            case .shelf: shelf
            case .switches: switches
            }
        }
        .padding(14)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in state.addToShelf([url]) } }
                }
            }
            return true
        }
    }

    private var volume: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let sys = state.system {
                sliderRow(icon: Image(systemName: "speaker.wave.3.fill"), name: "Gesamt", value: sys, range: 0...1) { state.setSystem($0) }
                    .fontWeight(.semibold)
                Divider()
            }
            if state.rows.isEmpty {
                Text("Gerade spielt keine App Ton ab.").foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(state.rows) { row in
                        sliderRow(icon: row.icon.map { Image(nsImage: $0) } ?? Image(systemName: row.symbol),
                                  name: row.name, value: state.level(row.id), range: 0...maxBoost) { state.setLevel(row, $0) }
                            .help("Über 100 % = lauter als normal")
                    }
                }
            }
            if let e = state.error { Text(e).font(.caption).foregroundStyle(.red).lineLimit(2) }
        }
    }

    private func sliderRow(icon: Image, name: String, value: Float, range: ClosedRange<Float>, set: @escaping (Float) -> Void) -> some View {
        HStack(spacing: 8) {
            icon.resizable().scaledToFit().frame(width: 20, height: 20)
            Text(name).lineLimit(1).frame(width: 160, alignment: .leading)
            Slider(value: Binding(get: { Double(value) }, set: { set(Float($0)) }), in: Double(range.lowerBound)...Double(range.upperBound))
                .accessibilityLabel("Lautstärke \(name)")
            Text("\(Int((value * 100).rounded())) %").monospacedDigit()
                .foregroundStyle(value > 1 ? .orange : .primary)
                .frame(width: 46, alignment: .trailing)
        }
    }

    private var shelf: some View {
        Group {
            if state.shelf.isEmpty {
                VStack {
                    Image(systemName: "tray.and.arrow.down").font(.title)
                    Text("Dateien hierher ziehen")
                }
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(state.shelf, id: \.self) { url in
                            VStack(spacing: 4) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 44, height: 44)
                                Text(url.lastPathComponent).font(.caption).lineLimit(2).multilineTextAlignment(.center).frame(width: 72)
                            }
                            .onDrag { NSItemProvider(object: url as NSURL) }
                            .contextMenu {
                                Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                Button("Aus Ablage entfernen") { state.shelf.removeAll { $0 == url } }
                            }
                            .help(url.path)
                        }
                    }
                }
                Button("Ablage leeren") { state.shelf = [] }.font(.caption)
            }
        }
    }

    private var switches: some View {
        VStack(alignment: .leading, spacing: 10) {
            if state.hasSafariMCP {
                HStack {
                    Image(systemName: "safari")
                    Text("Safari-MCP")
                    Spacer()
                    if let until = state.safariUntil {
                        Text("AN bis \(until.formatted(date: .omitted, time: .shortened))").foregroundStyle(.green)
                    } else {
                        Text("AUS").foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("30 Min") { state.setSafari(minutes: 30) }
                    Button("60 Min") { state.setSafari(minutes: 60) }
                    Button("Aus") { state.setSafari(minutes: nil) }
                }
                Divider()
            }
            HStack {
                Button("Alle Lautstärken zurücksetzen") { state.resetAll() }
                Spacer()
                Button("Beenden") { state.resetAll(); NSApp.terminate(nil) }
            }
        }
    }
}

struct NotchView: View {
    @ObservedObject var state: AppState
    let notch: CGSize
    let panel: CGSize

    var body: some View {
        let size = state.expanded ? panel : notch
        ZStack(alignment: .top) {
            UnevenRoundedRectangle(bottomLeadingRadius: state.expanded ? 22 : 10, bottomTrailingRadius: state.expanded ? 22 : 10)
                .fill(.black)
                .frame(width: size.width, height: size.height)
            if state.expanded {
                PanelContent(state: state)
                    .padding(.top, notch.height - 6)
                    .frame(width: panel.width, height: panel.height, alignment: .top)
                    .environment(\.colorScheme, .dark)
                    .transition(.opacity)
            }
        }
        .frame(width: panel.width, height: panel.height, alignment: .top)
        .animation(.spring(duration: 0.3), value: state.expanded)
    }
}

// ---------- Notch-Fenster ----------

@MainActor
final class NotchController {
    let state: AppState
    let panelSize = CGSize(width: 480, height: 220)
    var panel: NSPanel!
    var notchRect = NSRect.zero
    var panelRect = NSRect.zero
    var collapseAt: Date?

    init(state: AppState) {
        self.state = state
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .mainMenu + 3
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        layout()
        panel.orderFrontRegardless()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in self.layout() }
        }
        // shortcut: Abfrage alle 50 ms statt Event-Monitor – funktioniert auch während Finder-Drags, kostet kaum CPU
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in Task { @MainActor in self.tick() } }
    }

    func layout() {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
        let f = screen.frame
        var notch = CGSize(width: 185, height: max(24, f.maxY - screen.visibleFrame.maxY))  // ohne Notch: Pseudo-Notch
        if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            notch = CGSize(width: f.width - l.width - r.width, height: screen.safeAreaInsets.top)
        }
        panelRect = NSRect(x: f.midX - panelSize.width / 2, y: f.maxY - panelSize.height, width: panelSize.width, height: panelSize.height)
        notchRect = NSRect(x: f.midX - notch.width / 2, y: f.maxY - notch.height, width: notch.width, height: notch.height)
        panel.setFrame(panelRect, display: true)
        panel.contentView = NSHostingView(rootView: NotchView(state: state, notch: notch, panel: panelSize))
    }

    var preview = false

    func tick() {
        if preview { return }
        let p = NSEvent.mouseLocation
        let dragging = NSEvent.pressedMouseButtons & 1 != 0
        if !state.expanded {
            guard notchRect.insetBy(dx: -8, dy: -2).contains(p) else { return }
            // Beim Ziehen von Dateien gleich die Ablage zeigen
            if dragging, NSPasteboard(name: .drag).canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) {
                state.tab = .shelf
            }
            state.expanded = true
            panel.ignoresMouseEvents = false
            collapseAt = nil
        } else if panelRect.insetBy(dx: -16, dy: -16).contains(p) {
            collapseAt = nil
        } else if collapseAt == nil {
            collapseAt = Date().addingTimeInterval(0.4)
        } else if Date() >= collapseAt!, !dragging {
            state.expanded = false
            panel.ignoresMouseEvents = true  // eingeklappt: Klicks gehen an die Menüleiste darunter
            collapseAt = nil
        }
    }
}

// ---------- App ----------

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var state: AppState!
    var notch: NotchController?

    func applicationDidFinishLaunching(_ n: Notification) {
        MainActor.assumeIsolated {
            notch = NotchController(state: AppDelegate.state)
            // Vorschau für Screenshots: APPVOL_PREVIEW=volume|shelf|switches hält das Panel offen
            if let t = ProcessInfo.processInfo.environment["APPVOL_PREVIEW"], let tab = AppState.Tab.allCases.first(where: { "\($0)" == t }) {
                AppDelegate.state.tab = tab
                AppDelegate.state.expanded = true
                notch?.preview = true
            }
        }
    }

    func applicationWillTerminate(_ n: Notification) {
        MainActor.assumeIsolated { AppDelegate.state.resetAll() }
    }
}

@main
struct AppVolNotch: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var state: AppState

    init() {
        let s = AppState()
        AppDelegate.state = s
        _state = StateObject(wrappedValue: s)
    }

    var body: some Scene {
        MenuBarExtra("AppVol", systemImage: "speaker.wave.2.circle") {
            PanelContent(state: state).frame(width: 420, height: 240)
        }
        .menuBarExtraStyle(.window)
    }
}
