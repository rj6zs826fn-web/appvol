// Funktionen von AppVol: jede einzeln abschaltbar (Einstellungen → Funktionen).
// Neue Funktion: einen Fall in `Feature` ergänzen, Titel/Standard/Tab festlegen
// und in `FeatureViews` die Ansicht im Panel und den Abschnitt in den Einstellungen eintragen.

import SwiftUI

enum Feature: String, CaseIterable, Identifiable {
    case volume, claude, shelf, transcribe, safari, homeassistant

    var id: String { rawValue }

    var title: String {
        switch self {
        case .volume: "Lautstärke"
        case .claude: "Claude"
        case .shelf: "Ablage"
        case .transcribe: "Transkript"
        case .safari: "Safari-MCP"
        case .homeassistant: "Home Assistant"
        }
    }

    var summary: String {
        switch self {
        case .volume: "Gesamtlautstärke und Lautstärke pro App (0–300 %)"
        case .claude: "Status deiner Claude-Code-Sitzungen, Aufploppen bei fertig/Rückfrage"
        case .shelf: "Dateien per Drag & Drop kurz in der Notch ablegen"
        case .transcribe: "Video oder Audio auf die Notch ziehen → lokales Transkript (whisper.cpp)"
        case .safari: "Zeitschalter für einen lokalen Safari-MCP-Server"
        case .homeassistant: "Geräte und Sensoren aus deinem Home Assistant schalten und anzeigen"
        }
    }

    /// Ohne Einrichtung nutzlose Funktionen sind standardmäßig aus.
    var defaultOn: Bool {
        switch self {
        case .volume, .shelf: true
        case .claude, .safari, .homeassistant, .transcribe: false
        }
    }

    /// Hat einen eigenen Tab im Panel (sonst nur Einstellungen / Anzeige neben der Notch).
    var hasTab: Bool { true }
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

    enum ShelfClear: String, CaseIterable { case restart, interval }

    private init() {
        enabled = Set(Feature.allCases.filter { (UserDefaults.standard.object(forKey: "feature.\($0.rawValue)") as? Bool) ?? $0.defaultOn })
        shelfClear = ShelfClear(rawValue: d.string(forKey: "shelf.clear") ?? "") ?? .restart
        shelfHours = max(1, d.integer(forKey: "shelf.hours") == 0 ? 1 : d.integer(forKey: "shelf.hours"))
        safariDir = d.string(forKey: "safari.dir") ?? ""
        transcribeModel = d.string(forKey: "transcribe.model") ?? ""
        transcribeLang = d.string(forKey: "transcribe.lang") ?? "auto"
        transcribeCopy = d.bool(forKey: "transcribe.copy")
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
