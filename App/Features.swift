// Funktionen von AppVol: jede einzeln abschaltbar (Einstellungen → Funktionen).
// Neue Funktion: einen Fall in `Feature` ergänzen, Titel/Standard/Tab festlegen
// und in `FeatureViews` die Ansicht im Panel und den Abschnitt in den Einstellungen eintragen.

import SwiftUI

enum Feature: String, CaseIterable, Identifiable {
    case volume, outputDevice, media, claude, shelf, transcribe, safari, homeassistant, charging

    var id: String { rawValue }

    var title: String {
        switch self {
        case .volume: "Lautstärke"
        case .outputDevice: "Ausgabegerät"
        case .media: "Musik"
        case .claude: "Claude"
        case .shelf: "Ablage"
        case .transcribe: "Transkript"
        case .safari: "Safari-MCP"
        case .homeassistant: "Home Assistant"
        case .charging: "Ladeleistung"
        }
    }

    var summary: String {
        switch self {
        case .volume: "Gesamtlautstärke und Lautstärke pro App (0–300 %)"
        case .outputDevice: "Ausgabegerät oben im Lautstärke-Tab wechseln"
        case .media: "Was gerade läuft (Musik, Spotify, Browser …) mit Cover, Play/Pause, Vor/Zurück"
        case .claude: "Status deiner Claude-Code-Sitzungen, Aufploppen bei fertig/Rückfrage"
        case .shelf: "Dateien per Drag & Drop kurz in der Notch ablegen"
        case .transcribe: "Video oder Audio auf die Notch ziehen → lokales Transkript (whisper.cpp)"
        case .safari: "Zeitschalter für einen lokalen Safari-MCP-Server"
        case .homeassistant: "Geräte und Sensoren aus deinem Home Assistant schalten und anzeigen"
        case .charging: "Beim Laden die Leistung in Watt neben der Notch anzeigen"
        }
    }

    /// Symbol im Tab (SF Symbols); nur der aktive Tab zeigt zusätzlich den Titel, damit alle in die Notch passen.
    var icon: String {
        switch self {
        case .volume: "speaker.wave.2.fill"
        case .outputDevice: "hifispeaker.2"
        case .media: "music.note"
        case .claude: "sparkle"
        case .shelf: "tray.full"
        case .transcribe: "waveform"
        case .safari: "safari"
        case .homeassistant: "house"
        case .charging: "bolt.fill"
        }
    }

    /// Ohne Einrichtung nutzlose Funktionen sind standardmäßig aus.
    var defaultOn: Bool {
        switch self {
        case .volume, .outputDevice, .media, .shelf, .charging: true
        case .claude, .safari, .homeassistant, .transcribe: false
        }
    }

    /// Hat einen eigenen Tab im Panel (sonst nur Einstellungen / Anzeige neben der Notch).
    var hasTab: Bool { self != .outputDevice && self != .charging }
}

/// Lokale Einstellungen (UserDefaults). Persönliche Werte landen nur hier, nie im Code.
@MainActor
final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let d = UserDefaults.standard

    @Published var enabled: Set<Feature>
    @Published var shelfClear: ShelfClear { didSet { d.set(shelfClear.rawValue, forKey: "shelf.clear") } }
    @Published var shelfHours: Int { didSet { d.set(shelfHours, forKey: "shelf.hours") } }
    @Published var safariDir: String { didSet { d.set(safariDir, forKey: "safari.dir") } }
    @Published var transcribeModel: String { didSet { d.set(transcribeModel, forKey: "transcribe.model") } }
    @Published var transcribeLang: String { didSet { d.set(transcribeLang, forKey: "transcribe.lang") } }
    @Published var transcribeCopy: Bool { didSet { d.set(transcribeCopy, forKey: "transcribe.copy") } }
    // Claude-Teilfunktionen, standardmäßig aus
    @Published var claudePermissions: Bool { didSet { d.set(claudePermissions, forKey: "claude.permissions") } }
    @Published var claudeUsage: Bool { didSet { d.set(claudeUsage, forKey: "claude.usage") } }

    enum ShelfClear: String, CaseIterable { case restart, interval }

    private init() {
        // bool(forKey:) versteht auch "YES" aus Startargumenten (-feature.claude YES)
        enabled = Set(Feature.allCases.filter { UserDefaults.standard.object(forKey: "feature.\($0.rawValue)") == nil ? $0.defaultOn : UserDefaults.standard.bool(forKey: "feature.\($0.rawValue)") })
        shelfClear = ShelfClear(rawValue: d.string(forKey: "shelf.clear") ?? "") ?? .restart
        shelfHours = max(1, d.integer(forKey: "shelf.hours") == 0 ? 1 : d.integer(forKey: "shelf.hours"))
        safariDir = d.string(forKey: "safari.dir") ?? ""
        transcribeModel = d.string(forKey: "transcribe.model") ?? ""
        transcribeLang = d.string(forKey: "transcribe.lang") ?? "auto"
        transcribeCopy = d.bool(forKey: "transcribe.copy")
        claudePermissions = d.bool(forKey: "claude.permissions")
        claudeUsage = d.bool(forKey: "claude.usage")
    }

    func isOn(_ f: Feature) -> Bool { enabled.contains(f) }

    func set(_ f: Feature, _ on: Bool) {
        if on { enabled.insert(f) } else { enabled.remove(f) }
        d.set(on, forKey: "feature.\(f.rawValue)")
    }

    func binding(_ f: Feature) -> Binding<Bool> {
        Binding(get: { self.isOn(f) }, set: { self.set(f, $0) })
    }
}
