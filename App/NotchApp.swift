// AppVol Notch: Funktionen in der Notch und in der Menüleiste. Welche Funktionen es gibt, steht in Features.swift.

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
    let prefs = Prefs.shared
    let shelf = ShelfStore()
    let safari = SafariSwitch()
    let transcriber = Transcriber.shared
    let media = MediaPlayer()
    let outputs = OutputDevices()

    @Published var expanded = false
    @Published var tab: Feature = .volume
    @Published var popupUntil: Date?   // Notch ist von selbst aufgeklappt (z.B. Claude fertig)

    // Lautstärke
    @Published var rows: [AppRow] = []
    @Published var levels: [String: Float] = [:]
    @Published var error: String?
    @Published var system: Float?   // Gesamtlautstärke, nil = nicht regelbar
    private var taps: [String: VolumeTap] = [:]

    // Claude
    @Published var claude: [ClaudeSession] = []
    @Published var claudePermissions: [ClaudePermission] = []   // Freigaben, siehe ClaudeView.swift
    @Published var claudeUsage: ClaudeUsage?
    let monitor = ClaudeMonitor()
    private var lastClaudeStates: [String: String]?

    /// Tabs der eingeschalteten Funktionen in fester Reihenfolge.
    var tabs: [Feature] { Feature.allCases.filter { $0.hasTab && prefs.isOn($0) } }

    init() {
        mediaSelftest()
        onDefaultOutputChange { MainActor.assumeIsolated { self.outputChanged() } }
        refresh()
        refreshClaude()
        transcriber.onDone = { [weak self] url in self?.shelf.add([url]); self?.popup(.transcribe) }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in Task { @MainActor in self.refresh() } }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in Task { @MainActor in self.refreshClaude() } }
    }

    /// Klappt die Notch für ein paar Sekunden von selbst auf.
    func popup(_ f: Feature, seconds: Double = 6) {
        guard prefs.isOn(f) else { return }
        tab = f
        expanded = true
        popupUntil = Date().addingTimeInterval(seconds)
    }

    func refresh() {
        if !tabs.contains(tab), let first = tabs.first { tab = first }
        safari.refresh()
        media.keepRunning(prefs.isOn(.media))
        if prefs.isOn(.outputDevice) { outputs.refresh() }
        guard prefs.isOn(.volume) else { if !taps.isEmpty { resetAll() }; return }
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

    /// Standardgerät gewechselt (AirPods verbunden, Auswahl): Taps hängen noch am alten Gerät – mit gleicher Lautstärke neu anlegen.
    private func outputChanged() {
        outputs.refresh()
        system = systemVolume()
        for (key, old) in taps {
            old.stop()
            taps[key] = nil
            guard let row = rows.first(where: { $0.id == key }) else { levels[key] = nil; continue }
            do { taps[key] = try VolumeTap(processes: row.processes, volume: old.volume) }
            catch { self.error = "\(error)"; levels[key] = 1 }
        }
    }

    func resetAll() {
        taps.values.forEach { $0.stop() }
        taps = [:]; levels = [:]
    }

    func refreshClaude() {
        defer { refreshClaudeExtras() }
        guard prefs.isOn(.claude) else { claude = []; lastClaudeStates = nil; return }
        let list = monitor.load()
        if list != claude { claude = list }
        let states = Dictionary(uniqueKeysWithValues: list.map { ($0.id, "\($0.state)/\($0.needsInput)") })
        defer { lastClaudeStates = states }
        guard let prev = lastClaudeStates else { return }  // beim Start nicht aufploppen
        if list.contains(where: { $0.state != .working && prev[$0.id] != states[$0.id] }) { popup(.claude) }
    }

    func openClaude(_ s: ClaudeSession) {
        if let url = s.openURL { NSWorkspace.shared.open(url) }
        else if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") {
            NSWorkspace.shared.openApplication(at: app, configuration: .init())
        }
        if s.state == .done { monitor.dismiss(s) }
        popupUntil = nil
        expanded = false
        refreshClaude()
    }

    /// Anzeige links/rechts der Notch, solange Claude-Sitzungen aktiv sind.
    var claudeBadge: (working: Bool, count: Int, color: Color)? {
        guard prefs.isOn(.claude), !claude.isEmpty else { return nil }
        let color: Color = claude.contains { $0.needsInput } ? .orange : claude.contains { $0.state == .working } ? .white : .green
        return (claude.contains { $0.state == .working }, claude.count, color)
    }

    func addToShelf(_ urls: [URL]) {
        var urls = urls
        // Transkript-Tab offen: Audio/Video wird transkribiert statt abgelegt
        if prefs.isOn(.transcribe), tab == .transcribe {
            transcriber.enqueue(urls.filter(Transcriber.isMedia))
            urls.removeAll(where: Transcriber.isMedia)
            if urls.isEmpty { return }
        }
        guard prefs.isOn(.shelf) else { return }
        shelf.add(urls)
        tab = .shelf
    }
}

// ---------- Oberfläche ----------

/// Inhalt eines Tabs. Neue Funktion: hier ihren Fall eintragen.
struct FeatureTab: View {
    let feature: Feature
    @ObservedObject var state: AppState

    var body: some View {
        switch feature {
        case .volume: VolumeView(state: state)
        case .media: MediaView(media: state.media)
        case .outputDevice: EmptyView()  // kein eigener Tab, steckt im Lautstärke-Tab
        case .claude: ClaudeListView(state: state)
        case .shelf: ShelfView(store: state.shelf)
        case .transcribe: TranscribeView(t: state.transcriber)
        case .safari: SafariView(sw: state.safari)
        case .homeassistant: HomeAssistantView()
        }
    }
}

/// Abschnitt in den Einstellungen, sichtbar wenn die Funktion an ist. Neue Funktion: hier eintragen.
struct FeatureSettings: View {
    let feature: Feature

    var body: some View {
        switch feature {
        case .shelf: ShelfSettings()
        case .safari: SafariSettings()
        case .claude: ClaudeSettings()
        case .homeassistant: HomeAssistantSettings()
        case .transcribe: TranscribeSettings()
        case .volume, .outputDevice, .media: EmptyView()
        }
    }
}

struct PanelContent: View {
    @ObservedObject var state: AppState
    @ObservedObject var prefs = Prefs.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if state.tabs.count > 1 {
                    HStack(spacing: 4) {
                        ForEach(state.tabs) { f in
                            let on = f == state.tab
                            Button { state.tab = f } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: f.icon)
                                    if on { Text(f.title).lineLimit(1) }
                                }
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(on ? Color.white.opacity(0.14) : .clear, in: Capsule())
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(on ? .primary : .secondary)
                            .help(f.title).accessibilityLabel(f.title)
                        }
                    }
                    .animation(.snappy(duration: 0.2), value: state.tab)
                }
                Spacer(minLength: 0)
                SettingsLink { Image(systemName: "gearshape") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("Einstellungen")
            }
            if state.tabs.isEmpty {
                Text("Alle Funktionen sind aus. Einschalten unter Einstellungen.").foregroundStyle(.secondary)
            } else {
                FeatureTab(feature: state.tab, state: state)
            }
            Spacer(minLength: 0)
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
}

struct VolumeView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if state.prefs.isOn(.outputDevice) { OutputPicker(devices: state.outputs) }
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
}

struct SettingsView: View {
    @ObservedObject var state: AppState
    @ObservedObject var prefs = Prefs.shared

    var body: some View {
        Form {
            Section("Funktionen") {
                ForEach(Feature.allCases) { f in
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(isOn: prefs.binding(f)) {
                            VStack(alignment: .leading) {
                                Text(f.title)
                                Text(f.summary).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if prefs.isOn(f) { FeatureSettings(feature: f).padding(.leading, 12) }
                    }
                }
            }
            Section("Allgemein") {
                HStack {
                    Button("Alle Lautstärken zurücksetzen") { state.resetAll() }
                    Spacer()
                    Button("AppVol beenden") { state.resetAll(); NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 560)
        .onAppear { NSApp.activate(ignoringOtherApps: true) }
    }
}

// ---------- Notch ----------

/// Notch-Form: oben nach außen gewölbte „Ohren“, unten abgerundet – wächst mit der Animation.
struct NotchShape: Shape {
    var top: CGFloat
    var bottom: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(top, bottom) }
        set { top = newValue.first; bottom = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + top, y: r.minY + top), control: CGPoint(x: r.minX + top, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + top, y: r.maxY - bottom))
        p.addQuadCurve(to: CGPoint(x: r.minX + top + bottom, y: r.maxY), control: CGPoint(x: r.minX + top, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - top - bottom, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - top, y: r.maxY - bottom), control: CGPoint(x: r.maxX - top, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - top, y: r.minY + top))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - top, y: r.minY))
        p.closeSubpath()
        return p
    }
}

struct NotchView: View {
    @ObservedObject var state: AppState
    @ObservedObject var ha = HAStore.shared
    let notch: CGSize
    let panel: CGSize
    static let wing: CGFloat = 34   // Breite der Anzeige links/rechts der Notch

    var body: some View {
        let badge = state.claudeBadge
        let open = state.expanded
        let ear: CGFloat = open ? 14 : 6
        let haWings = badge == nil ? ha.wings : []  // Claude hat Vorrang neben der Notch
        let wing = badge != nil ? Self.wing : haWings.isEmpty ? 0 : HAStore.wingWidth
        let size = open ? panel : CGSize(width: notch.width + 2 * ear + 2 * wing, height: notch.height)
        let shape = NotchShape(top: ear, bottom: open ? 24 : 10)

        ZStack(alignment: .top) {
            if !open, let b = badge {
                HStack(spacing: 0) {
                    Image(systemName: "sparkle").foregroundStyle(b.working ? .orange : b.color)
                        .symbolEffect(.pulse, isActive: b.working)
                        .frame(width: Self.wing)
                    Spacer(minLength: notch.width)
                    Text("\(b.count)").font(.system(size: 12, weight: .bold)).monospacedDigit().foregroundStyle(b.color)
                        .frame(width: Self.wing)
                }
                .padding(.horizontal, ear)
                .frame(width: size.width, height: notch.height)
                .transition(.opacity)
                .accessibilityLabel("\(b.count) Claude-Sitzungen")
            }
            if !open, !haWings.isEmpty { HANotchWings(values: haWings, notch: notch, ear: ear, width: size.width) }
            if open {
                // Inhalt hat feste Panelgröße und wird von der wachsenden Form freigelegt – läuft nie voraus
                PanelContent(state: state)
                    .padding(.top, notch.height - 6)
                    .padding(.horizontal, ear)
                    .frame(width: panel.width, height: panel.height, alignment: .top)
                    .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.18).delay(0.12)),
                                            removal: .opacity.animation(.easeIn(duration: 0.08))))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(shape.fill(.black))
        .clipShape(shape)
        .shadow(color: .black.opacity(open ? 0.45 : 0), radius: 14, y: 6)
        .environment(\.colorScheme, .dark)
        .frame(width: panel.width + 40, height: panel.height + 30, alignment: .top)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: open)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: badge == nil)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: haWings.isEmpty)
    }
}

@MainActor
final class NotchController {
    let state: AppState
    let panelSize = CGSize(width: 500, height: 240)
    var panel: NSPanel!
    var notchRect = NSRect.zero
    var panelRect = NSRect.zero
    var collapseAt: Date?
    var preview = false

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
        // Fenster etwas größer als das Panel, damit der Schatten Platz hat
        let win = CGSize(width: panelSize.width + 40, height: panelSize.height + 30)
        panel.setFrame(NSRect(x: f.midX - win.width / 2, y: f.maxY - win.height, width: win.width, height: win.height), display: true)
        panelRect = NSRect(x: f.midX - panelSize.width / 2, y: f.maxY - panelSize.height, width: panelSize.width, height: panelSize.height)
        notchRect = NSRect(x: f.midX - notch.width / 2, y: f.maxY - notch.height, width: notch.width, height: notch.height)
        panel.contentView = NSHostingView(rootView: NotchView(state: state, notch: notch, panel: panelSize))
    }

    func tick() {
        if preview { return }
        let p = NSEvent.mouseLocation
        let dragging = NSEvent.pressedMouseButtons & 1 != 0
        let overPanel = panelRect.insetBy(dx: -16, dy: -16).contains(p)
        // Von selbst aufgeklappt: einige Sekunden offen lassen, außer die Maus übernimmt
        if let until = state.popupUntil {
            if overPanel { state.popupUntil = nil }
            else if Date() < until { panel.ignoresMouseEvents = false; return }
            else { state.popupUntil = nil; state.expanded = false }
        }
        if !state.expanded {
            panel.ignoresMouseEvents = true  // eingeklappt: Klicks gehen an die Menüleiste darunter
            // Hover-Zone schließt die Anzeige links/rechts der Notch ein (Claude bzw. Home-Assistant-Werte)
            let wing = state.claudeBadge != nil ? NotchView.wing + 8 : HAStore.shared.wings.isEmpty ? 8 : HAStore.wingWidth + 8
            guard notchRect.insetBy(dx: -wing, dy: -2).contains(p) else { return }
            // Beim Ziehen von Dateien gleich die Ablage zeigen – außer der Transkript-Tab ist offen
            if dragging, state.tab != .transcribe, state.prefs.isOn(.shelf),
               NSPasteboard(name: .drag).canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) {
                state.tab = .shelf
            }
            state.expanded = true
            panel.ignoresMouseEvents = false
            collapseAt = nil
        } else if overPanel {
            collapseAt = nil
        } else if collapseAt == nil {
            collapseAt = Date().addingTimeInterval(0.4)
        } else if Date() >= collapseAt!, !dragging {
            state.expanded = false
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
            if let f = ProcessInfo.processInfo.environment["APPVOL_TRANSCRIBE"] { Transcriber.selfTest(f); return }
            notch = NotchController(state: AppDelegate.state)
            // Vorschau für Screenshots: APPVOL_PREVIEW=<Funktion, z.B. volume> hält das Panel offen
            if let t = ProcessInfo.processInfo.environment["APPVOL_PREVIEW"], let f = Feature(rawValue: t) {
                AppDelegate.state.tab = f
                AppDelegate.state.expanded = true
                notch?.preview = true
            }
        }
    }

    func applicationWillTerminate(_ n: Notification) {
        MainActor.assumeIsolated { AppDelegate.state.resetAll(); AppDelegate.state.media.stop() }
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
            PanelContent(state: state).frame(width: 460, height: 260)
        }
        .menuBarExtraStyle(.window)

        Settings { SettingsView(state: state) }
    }
}
