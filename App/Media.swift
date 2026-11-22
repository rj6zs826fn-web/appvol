// Musiksteuerung: „Was läuft gerade“ (Musik, Spotify, Browser …) mit Cover und Play/Pause/Vor/Zurück.
// Seit macOS 15.4 darf nur Apple selbst MediaRemote nutzen. Der MediaRemoteAdapter (BSD-3, vendor/)
// lädt dafür ein kleines Framework in das berechtigte /usr/bin/perl und schreibt JSON-Zeilen nach stdout.

import AppKit
import SwiftUI

@MainActor
final class MediaPlayer: ObservableObject {
    struct Track: Equatable {
        var title = "", artist = "", app: String?, playing = false
        var artwork: NSImage?
    }

    @Published private(set) var track: Track?
    @Published private(set) var broken = false   // Adapter startet nicht (z.B. nach einem macOS-Update)
    private var process: Process?
    private var info: [String: Any] = [:]
    private var buffer = Data()
    private var failures = 0

    private static let script = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl")
    private static let framework = Bundle.main.privateFrameworksURL?.appendingPathComponent("MediaRemoteAdapter.framework")

    /// Vom 2-s-Timer aufgerufen: startet/stoppt den Stream passend zum Schalter, startet ihn nach Absturz neu.
    func keepRunning(_ on: Bool) {
        if !on { stop(); return }
        guard process?.isRunning != true, failures < 3 else { return }  // nach 3 Fehlstarts aufgeben
        start()
    }

    private func start() {
        guard let p = adapter(["stream", "--debounce=150"]) else { broken = true; return }
        let out = Pipe()
        p.standardOutput = out
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }  // EOF
            Task { @MainActor in self.receive(d) }
        }
        p.terminationHandler = { p in
            Task { @MainActor in
                guard self.process === p else { return }  // selbst beendet
                self.process = nil
                if p.terminationStatus != 0 { self.failures += 1; self.broken = self.failures >= 3 }
            }
        }
        do { try p.run(); process = p } catch { failures += 1; broken = failures >= 3 }
    }

    func stop() {
        process?.terminate(); process = nil
        info = [:]; buffer = Data(); track = nil
    }

    private func receive(_ d: Data) {
        guard process != nil else { return }  // Nachzügler nach stop()
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let msg = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let payload = msg["payload"] as? [String: Any] else { continue }
            failures = 0
            info = Self.merge(info, payload, diff: msg["diff"] as? Bool ?? false)
            track = Self.track(info)
        }
    }

    /// Diff-Format des Adapters: `diff` = nur geänderte Schlüssel, `null` = Schlüssel entfällt.
    nonisolated static func merge(_ old: [String: Any], _ payload: [String: Any], diff: Bool) -> [String: Any] {
        var r = diff ? old : [:]
        for (k, v) in payload { r[k] = v is NSNull ? nil : v }
        return r
    }

    private static func track(_ i: [String: Any]) -> Track? {
        guard let title = i["title"] as? String else { return nil }
        let bundle = i["parentApplicationBundleIdentifier"] as? String ?? i["bundleIdentifier"] as? String
        let appURL = bundle.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        let art = (i["artworkData"] as? String).flatMap { Data(base64Encoded: $0) }.flatMap(NSImage.init(data:))
            ?? appURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
        return Track(title: title, artist: i["artist"] as? String ?? "",
                     app: appURL.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") },
                     playing: i["playing"] as? Bool ?? false, artwork: art)
    }

    /// MediaRemote-Befehle: 2 = Play/Pause, 4 = nächster, 5 = vorheriger Titel.
    func send(_ command: Int) {
        try? adapter(["send", String(command)])?.run()
    }

    private func adapter(_ args: [String]) -> Process? {
        guard let s = Self.script, let f = Self.framework, FileManager.default.fileExists(atPath: f.path) else { return nil }
        let p = Process()
        // Wächter-Shell: beendet perl, sobald AppVol weg ist (auch nach kill -9), sonst bliebe der Stream als Waise übrig
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "\"$@\" & c=$!; trap 'kill $c' TERM; while kill -0 \(getpid()) 2>/dev/null && kill -0 $c 2>/dev/null; do sleep 2; done; kill $c 2>/dev/null; wait $c",
                       "sh", "/usr/bin/perl", s.path, f.path] + args
        p.standardError = FileHandle.nullDevice
        return p
    }
}

struct MediaView: View {
    @ObservedObject var media: MediaPlayer

    var body: some View {
        if let t = media.track {
            HStack(spacing: 14) {
                Group {
                    if let a = t.artwork { Image(nsImage: a).resizable().scaledToFill() }
                    else { Image(systemName: "music.note").font(.largeTitle).foregroundStyle(.secondary) }
                }
                .frame(width: 96, height: 96).clipShape(RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(t.title).font(.headline).lineLimit(2)
                    Text(t.artist).foregroundStyle(.secondary).lineLimit(1)
                    if let app = t.app { Text(app).font(.caption).foregroundStyle(.tertiary) }
                    HStack(spacing: 22) {
                        button("backward.fill", "Vorheriger Titel") { media.send(5) }
                        button(t.playing ? "pause.fill" : "play.fill", t.playing ? "Pause" : "Abspielen") { media.send(2) }
                            .font(.title)
                        button("forward.fill", "Nächster Titel") { media.send(4) }
                    }
                    .font(.title2).padding(.top, 6)
                }
                Spacer(minLength: 0)
            }
        } else {
            Text(media.broken ? "Wiedergabe-Info ist nicht verfügbar. Vermutlich hat ein macOS-Update den Zugriff gesperrt (siehe README, Musiksteuerung)."
                              : "Gerade läuft nichts.")
                .foregroundStyle(.secondary)
        }
    }

    private func button(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }.buttonStyle(.plain).accessibilityLabel(label)
    }
}

func mediaSelftest() {
    let a = MediaPlayer.merge([:], ["title": "A", "artist": "X"], diff: false)
    let b = MediaPlayer.merge(a, ["title": "B", "artist": NSNull()], diff: true)
    precondition(b["title"] as? String == "B" && b["artist"] == nil)
    precondition(MediaPlayer.merge(b, ["playing": true], diff: false).count == 1)
}
