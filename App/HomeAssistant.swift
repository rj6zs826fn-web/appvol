// Home Assistant: gewählte Entitäten als Kacheln im Panel, optional bis zu 2 Sensoren neben der Notch.
// Adresse und Auswahl liegen in UserDefaults, der Token nur im macOS-Schlüsselbund. Nichts davon steht im Code.

import Security
import SwiftUI

struct HAEntity: Identifiable, Equatable {
    let id: String      // entity_id, z. B. sensor.wohnzimmer_temperatur
    let name: String
    let state: String
    let unit: String
    var domain: String { String(id.prefix { $0 != "." }) }

    /// Wert für die Anzeige: Zahlen auf höchstens eine Nachkommastelle, bekannte Zustände auf Deutsch.
    var display: String {
        let words = ["on": "an", "off": "aus", "open": "offen", "closed": "zu", "opening": "öffnet", "closing": "schließt",
                     "unavailable": "nicht verfügbar", "unknown": "unbekannt"]
        let v = Double(state).map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? words[state] ?? state
        return unit.isEmpty ? v : "\(v) \(unit)"
    }
}

enum HAError: LocalizedError, Equatable {
    case noURL, noToken, unreachable, insecure, token, http(Int), format

    // Bewusst ohne Token, Header oder Antworttext: Fehlermeldungen dürfen nie Geheimnisse enthalten.
    var errorDescription: String? {
        switch self {
        case .noURL: "Keine gültige Adresse eingestellt (z. B. http://homeassistant.local:8123)."
        case .noToken: "Kein Token eingetragen."
        case .unreachable: "Home Assistant nicht erreichbar. Adresse und Netzwerk prüfen."
        case .insecure: "http ist nur im Heimnetz erlaubt (.local oder IP-Adresse). Sonst https verwenden."
        case .token: "Token ungültig oder abgelaufen."
        case .http(let c): "Home Assistant meldet Fehler \(c)."
        case .format: "Unerwartete Antwort. Ist das die Adresse von Home Assistant?"
        }
    }
}

enum HA {
    static let toggles: Set<String> = ["switch", "light", "input_boolean", "fan"]

    /// Folgt keinen Weiterleitungen: der Token geht nur an die eingetragene Adresse.
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ s: URLSession, task: URLSessionTask, willPerformHTTPRedirection r: HTTPURLResponse,
                        newRequest: URLRequest) async -> URLRequest? { nil }
    }
    private static let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)

    static func request(_ base: String, _ token: String, _ path: String, body: [String: String]? = nil) async throws -> Data {
        guard let b = URL(string: base.trimmingCharacters(in: .whitespaces)), ["http", "https"].contains(b.scheme?.lowercased() ?? ""),
              b.host != nil else { throw HAError.noURL }
        guard !token.isEmpty else { throw HAError.noToken }
        var r = URLRequest(url: b.appendingPathComponent(path), timeoutInterval: 5)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            r.httpMethod = "POST"
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: r) }
        catch let e as URLError where e.code == .appTransportSecurityRequiresSecureConnection { throw HAError.insecure }
        catch { throw HAError.unreachable }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw HAError.token }
        guard (200..<300).contains(code) else { throw HAError.http(code) }
        return data
    }

    /// Antwort von GET /api/states → Entitäten, nach Name sortiert.
    static func parse(_ data: Data) throws -> [HAEntity] {
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { throw HAError.format }
        return arr.compactMap { o -> HAEntity? in
            guard let id = o["entity_id"] as? String else { return nil }
            let a = o["attributes"] as? [String: Any] ?? [:]
            return HAEntity(id: id, name: a["friendly_name"] as? String ?? id, state: "\(o["state"] ?? "")",
                            unit: a["unit_of_measurement"] as? String ?? "")
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Selbsttest ohne Netz: APPVOL_HA_SELFTEST=1 prüft das Parsen und füllt das Panel mit Beispieldaten.
    static let sample = Data("""
    [{"entity_id":"sensor.pv_leistung","state":"1234.56","attributes":{"friendly_name":"PV-Leistung","unit_of_measurement":"W"}},
     {"entity_id":"switch.steckdose","state":"on","attributes":{"friendly_name":"Steckdose"}},
     {"entity_id":"cover.rollo","state":"closed","attributes":{"friendly_name":"Rollo"}},
     {"entity_id":"scene.abends","state":"unknown","attributes":{"friendly_name":"Abends"}},
     {"state":"kaputt ohne entity_id"}]
    """.utf8)

    static func selftest() -> [HAEntity] {
        let e = try! parse(sample)
        precondition(e.map(\.id) == ["scene.abends", "sensor.pv_leistung", "cover.rollo", "switch.steckdose"])
        precondition(e[1].domain == "sensor" && e[1].unit == "W" && e[3].display == "an")
        precondition((try? parse(Data("{\"message\":\"x\"}".utf8))) == nil)
        print("HA-Selbsttest ok")
        return e
    }
}

/// Token im Schlüsselbund (kSecClassGenericPassword), nie in UserDefaults oder Dateien.
enum HAKeychain {
    private static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                               kSecAttrService as String: "AppVol Home Assistant",
                                               kSecAttrAccount as String: "token"]

    static func read() -> String {
        var out: AnyObject?
        let q = query.merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { $1 }
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return "" }
        return String(decoding: d, as: UTF8.self)
    }

    static func save(_ token: String) {
        SecItemDelete(query as CFDictionary)
        if !token.isEmpty { SecItemAdd(query.merging([kSecValueData as String: Data(token.utf8)]) { $1 } as CFDictionary, nil) }
    }
}

@MainActor
final class HAStore: ObservableObject {
    static let shared = HAStore()
    static let wingWidth: CGFloat = 64
    private let d = UserDefaults.standard

    @Published var entities: [HAEntity] = []
    @Published var error: String?
    @Published var url: String { didSet { d.set(url, forKey: "ha.url") } }
    @Published var shown: [String] { didSet { d.set(shown, forKey: "ha.shown") } }     // Kacheln im Panel
    @Published var notch: [String] { didSet { d.set(notch, forKey: "ha.notch") } }     // höchstens 2 Sensoren
    @Published private(set) var hasToken: Bool
    private var token: String
    private var busy = false
    private var demo = false

    private init() {
        url = d.string(forKey: "ha.url") ?? ""
        shown = d.stringArray(forKey: "ha.shown") ?? []
        notch = d.stringArray(forKey: "ha.notch") ?? []
        // Schlüsselbund erst lesen, wenn die Funktion an ist – sonst fragt macOS evtl. ohne Grund nach
        token = Prefs.shared.isOn(.homeassistant) ? HAKeychain.read() : ""
        hasToken = !token.isEmpty
        if ProcessInfo.processInfo.environment["APPVOL_HA_SELFTEST"] != nil { entities = HA.selftest(); demo = true }
        Timer.scheduledTimer(withTimeInterval: 7, repeats: true) { _ in Task { @MainActor in self.refresh() } }
        refresh()
    }

    var tiles: [HAEntity] { shown.compactMap { id in entities.first { $0.id == id } } }

    /// Werte neben der Notch, nur wenn die Funktion an ist und der Nutzer Sensoren gewählt hat.
    var wings: [String] {
        guard Prefs.shared.isOn(.homeassistant) else { return [] }
        return notch.prefix(2).compactMap { id in entities.first { $0.id == id }?.display }
    }

    func setToken(_ t: String) {
        token = t.trimmingCharacters(in: .whitespacesAndNewlines)
        HAKeychain.save(token)
        hasToken = !token.isEmpty
        if !hasToken { entities = [] }
    }

    func refresh() {
        guard Prefs.shared.isOn(.homeassistant), !demo, !busy else { return }
        if token.isEmpty { token = HAKeychain.read(); hasToken = !token.isEmpty }
        busy = true
        Task {
            defer { busy = false }
            do {
                let list = try HA.parse(try await HA.request(url, token, "api/states"))
                if list != entities { entities = list }
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func call(_ e: HAEntity, _ service: String) {
        Task {
            do {
                _ = try await HA.request(url, token, "api/services/\(e.domain)/\(service)", body: ["entity_id": e.id])
                try? await Task.sleep(for: .milliseconds(400))
                refresh()
            } catch { self.error = error.localizedDescription }
        }
    }

    func toggle(_ list: ReferenceWritableKeyPath<HAStore, [String]>, _ id: String, max: Int = .max) {
        if let i = self[keyPath: list].firstIndex(of: id) { self[keyPath: list].remove(at: i) }
        else if self[keyPath: list].count < max { self[keyPath: list].append(id) }
    }
}

// ---------- Panel ----------

struct HomeAssistantView: View {
    @ObservedObject var store = HAStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let e = store.error { Text(e).font(.caption).foregroundStyle(.red).lineLimit(2) }
            if store.tiles.isEmpty {
                Text(store.url.isEmpty ? "Home Assistant ist noch nicht eingerichtet (Einstellungen → Home Assistant)."
                                       : "Keine Entitäten gewählt (Einstellungen → Home Assistant).")
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], spacing: 8) {
                    ForEach(store.tiles) { HATile(e: $0, store: store) }
                }
            }
        }
    }
}

struct HATile: View {
    let e: HAEntity
    let store: HAStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(e.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            control.frame(height: 24)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .help(e.id)
    }

    @ViewBuilder private var control: some View {
        let off = e.state == "unavailable"
        switch e.domain {
        case _ where HA.toggles.contains(e.domain):
            Toggle(e.name, isOn: Binding(get: { e.state == "on" }, set: { _ in store.call(e, "toggle") }))
                .toggleStyle(.switch).labelsHidden().disabled(off)
        case "cover":
            HStack(spacing: 4) {
                Button { store.call(e, "open_cover") } label: { Image(systemName: "chevron.up") }.accessibilityLabel("\(e.name) öffnen")
                Button { store.call(e, "stop_cover") } label: { Image(systemName: "stop.fill") }.accessibilityLabel("\(e.name) stoppen")
                Button { store.call(e, "close_cover") } label: { Image(systemName: "chevron.down") }.accessibilityLabel("\(e.name) schließen")
                Text(e.display).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .disabled(off)
        case "scene", "script":
            Button("Ausführen") { store.call(e, "turn_on") }.disabled(off).accessibilityLabel("\(e.name) ausführen")
        default:
            Text(e.display).font(.title3.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
        }
    }
}

/// Werte links/rechts der eingeklappten Notch. Bei nur einem Sensor steht links ein Haus.
struct HANotchWings: View {
    let values: [String]
    let notch: CGSize
    let ear: CGFloat
    let width: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Group { if values.count > 1 { Text(values[0]) } else { Image(systemName: "house.fill") } }.frame(width: HAStore.wingWidth)
            Spacer(minLength: notch.width)
            Text(values.last ?? "").frame(width: HAStore.wingWidth)
        }
        .font(.system(size: 11, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
        .foregroundStyle(.white)
        .padding(.horizontal, ear)
        .frame(width: width, height: notch.height)
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Home Assistant: \(values.joined(separator: ", "))")
    }
}

// ---------- Einstellungen ----------

struct HomeAssistantSettings: View {
    @ObservedObject var store = HAStore.shared
    @State private var tokenInput = ""
    @State private var search = ""

    var body: some View {
        TextField("Adresse", text: $store.url, prompt: Text("http://homeassistant.local:8123"))
        if store.url.lowercased().hasPrefix("http://") {
            Text("Unverschlüsselt (http): im Heimnetz ok, von unterwegs besser https.").font(.caption).foregroundStyle(.orange)
        }
        HStack {
            SecureField("Token", text: $tokenInput, prompt: Text(store.hasToken ? "gespeichert im Schlüsselbund" : "Long-Lived Access Token"))
            if store.hasToken { Button("Entfernen") { store.setToken(""); tokenInput = "" } }
        }
        HStack {
            Button("Verbindung testen") {
                if !tokenInput.isEmpty { store.setToken(tokenInput); tokenInput = "" }
                store.refresh()
            }
            if let e = store.error { Text(e).font(.caption).foregroundStyle(.red) }
            else if !store.entities.isEmpty { Text("Verbunden, \(store.entities.count) Entitäten").font(.caption).foregroundStyle(.green) }
        }
        if !store.entities.isEmpty {
            TextField("Suchen", text: $search, prompt: Text("Name oder entity_id"))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(store.entities.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search) }) { e in
                        HStack {
                            Toggle("Panel", isOn: Binding(get: { store.shown.contains(e.id) }, set: { _ in store.toggle(\.shown, e.id) }))
                                .toggleStyle(.checkbox).accessibilityLabel("\(e.name) im Panel zeigen")
                            // Nur Sensoren können neben die Notch; bei anderen unsichtbar, damit die Spalten bündig bleiben
                            Toggle("Notch", isOn: Binding(get: { store.notch.contains(e.id) }, set: { _ in store.toggle(\.notch, e.id, max: 2) }))
                                .toggleStyle(.checkbox).accessibilityLabel("\(e.name) neben der Notch zeigen")
                                .disabled(e.domain != "sensor" || (store.notch.count >= 2 && !store.notch.contains(e.id)))
                                .opacity(e.domain == "sensor" ? 1 : 0).accessibilityHidden(e.domain != "sensor")
                            VStack(alignment: .leading) {
                                Text(e.name).lineLimit(1)
                                Text(e.id).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(e.display).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            .frame(height: 220)
        }
        Text("„Panel“ zeigt die Entität als Kachel, „Notch“ zeigt bis zu 2 Sensoren neben der Notch. Anleitung: README, Abschnitt Home Assistant.")
            .font(.caption).foregroundStyle(.secondary)
    }
}
