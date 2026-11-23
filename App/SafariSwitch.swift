// Zeitschalter für einen lokalen Safari-MCP-Server (siehe eigenes Repo „safari-mcp“).
// Der Server liest `<Ordner>/.enabled_until` (Unix-Zeit). AppVol schreibt nur diese Datei.

import AppKit
import SwiftUI

@MainActor
final class SafariSwitch: ObservableObject {
    @Published private(set) var until: Date?
    private var flag: URL? {
        let dir = Prefs.shared.safariDir
        return dir.isEmpty ? nil : URL(fileURLWithPath: (dir as NSString).expandingTildeInPath).appendingPathComponent(".enabled_until")
    }

    func refresh() {
        guard let f = flag, let t = try? String(contentsOf: f, encoding: .utf8),
              let v = Double(t.trimmingCharacters(in: .whitespacesAndNewlines)), v > Date().timeIntervalSince1970 else { until = nil; return }
        until = Date(timeIntervalSince1970: v)
    }

    func set(minutes: Double?) {
        guard let f = flag else { return }
        let v = minutes.map { Date().timeIntervalSince1970 + $0 * 60 } ?? 0
        try? String(v).write(to: f, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f.path)  // nur der Nutzer
        if minutes == nil { closeClaudeWindow(dir: f.deletingLastPathComponent()) }
        refresh()
    }

    /// `server.py off` schließt zusätzlich Claudes eigenes Safari-Fenster. Aus ist oben schon geschrieben,
    /// das hier ist nur Aufräumen: fehlt python3 oder server.py, bleibt nur das Fenster offen.
    private func closeClaudeWindow(dir: URL) {
        let script = dir.appendingPathComponent("server.py")
        guard FileManager.default.fileExists(atPath: script.path) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-I", script.path, "off"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}

struct SafariView: View {
    @ObservedObject var sw: SafariSwitch
    @ObservedObject var prefs = Prefs.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if prefs.safariDir.isEmpty {
                Text("Kein Safari-MCP-Ordner eingestellt (Einstellungen → Safari-MCP).").foregroundStyle(.secondary)
            } else {
                HStack {
                    Image(systemName: "safari")
                    Text("Safari-Zugriff für Claude")
                    Spacer()
                    if let u = sw.until { Text("AN bis \(u.formatted(date: .omitted, time: .shortened))").foregroundStyle(.green) }
                    else { Text("AUS").foregroundStyle(.secondary) }
                }
                HStack {
                    Button("30 Min") { sw.set(minutes: 30) }
                    Button("60 Min") { sw.set(minutes: 60) }
                    Button("Aus") { sw.set(minutes: nil) }
                }
            }
        }
    }
}

struct SafariSettings: View {
    @ObservedObject var prefs = Prefs.shared

    var body: some View {
        HStack {
            TextField("Ordner des Safari-MCP-Servers", text: $prefs.safariDir)
            Button("Wählen …") {
                let p = NSOpenPanel()
                p.canChooseDirectories = true; p.canChooseFiles = false
                if p.runModal() == .OK, let u = p.url { prefs.safariDir = u.path }
            }
        }
        Text("Der Ordner, in dem `server.py` des Safari-MCP liegt. Anleitung: siehe README, Abschnitt Safari-MCP.")
            .font(.caption).foregroundStyle(.secondary)
    }
}
