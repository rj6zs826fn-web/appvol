// Transkript: Video oder Audio auf die Notch ziehen (Tab „Transkript“ offen) → lokales Transkript als .txt.
// Braucht ffmpeg und whisper-cli (Homebrew: ffmpeg, whisper-cpp) und ein ggml-Modell von whisper.cpp.
// Alles läuft lokal; Dateinamen gehen nur als Argumente an Process, nie durch eine Shell.

import AppKit
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers

struct Fail: LocalizedError {
    let errorDescription: String?
    init(_ s: String) { errorDescription = s }
}

struct WhisperModel: Identifiable, Hashable {
    let file: String, label: String, size: Int64, sha256: String
    var id: String { file }
    var local: URL { Self.dir.appendingPathComponent(file) }
    var url: URL { URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(file)")! }

    static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AppVol/models", isDirectory: true)
    // Größe und SHA-256 laut Hugging Face (X-Linked-Size / X-Linked-ETag)
    static let all = [
        WhisperModel(file: "ggml-base.bin", label: "base (≈ 150 MB, schnell)", size: 147_951_465,
                     sha256: "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe"),
        WhisperModel(file: "ggml-small.bin", label: "small (≈ 490 MB)", size: 487_601_967,
                     sha256: "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b"),
        WhisperModel(file: "ggml-large-v3-turbo-q5_0.bin", label: "large-v3-turbo (≈ 570 MB, beste Qualität)", size: 574_041_195,
                     sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"),
    ]

    /// Läuft im Hintergrund (Download-Callback), nicht auf dem Main-Thread.
    static func verify(_ file: URL, _ m: WhisperModel) throws {
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value
        guard size == m.size else { throw Fail("Download unvollständig (Größe stimmt nicht)") }
        let h = try FileHandle(forReadingFrom: file)
        defer { try? h.close() }
        var sha = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { sha.update(data: chunk) }
        guard sha.finalize().map({ String(format: "%02x", $0) }).joined() == m.sha256 else { throw Fail("Prüfsumme stimmt nicht") }
    }
}

/// Sucht ein Programm in den Homebrew-Ordnern und im PATH.
func findTool(_ name: String) -> String? {
    let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
    return (["/opt/homebrew/bin", "/usr/local/bin"] + path).map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
}

@MainActor
final class Transcriber: ObservableObject {
    static let shared = Transcriber()

    @Published private(set) var status: String?      // nil = nichts läuft
    @Published private(set) var progress: Double?     // nil = unbekannt
    @Published private(set) var queue: [URL] = []
    @Published private(set) var last: URL?
    @Published private(set) var error: String?
    @Published private(set) var downloading: (file: String, fraction: Double)?
    var onDone: ((URL) -> Void)?
    private var job: Task<Void, Never>?
    private var dl: URLSessionDownloadTask?

    var ready: Bool { findTool("ffmpeg") != nil && findTool("whisper-cli") != nil && FileManager.default.fileExists(atPath: Prefs.shared.transcribeModel) }

    static func isMedia(_ u: URL) -> Bool {
        (try? u.resourceValues(forKeys: [.contentTypeKey]).contentType)?.conforms(to: .audiovisualContent) ?? false
    }

    func enqueue(_ urls: [URL]) {
        queue += urls
        guard job == nil, !queue.isEmpty else { return }
        job = Task {
            while !queue.isEmpty, !Task.isCancelled {
                let src = queue.removeFirst()
                do { let out = try await transcribe(src); last = out; error = nil; onDone?(out) }
                catch is CancellationError { break }
                catch { self.error = "\(src.lastPathComponent): \(error.localizedDescription)" }
            }
            status = nil; progress = nil; queue = []; job = nil
        }
    }

    func cancel() { job?.cancel() }

    func transcribe(_ src: URL) async throws -> URL {
        guard let ffmpeg = findTool("ffmpeg"), let whisper = findTool("whisper-cli") else { throw Fail("ffmpeg oder whisper-cli fehlt (Einstellungen → Transkript)") }
        let model = Prefs.shared.transcribeModel
        guard FileManager.default.fileExists(atPath: model) else { throw Fail("Kein Modell gewählt (Einstellungen → Transkript)") }
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("appvol-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp); status = nil; progress = nil }
        let wav = tmp.appendingPathComponent("audio.wav"), log = tmp.appendingPathComponent("log.txt")

        status = "Umwandeln: \(src.lastPathComponent)"; progress = nil
        try await run(ffmpeg, ["-nostdin", "-v", "error", "-y", "-i", src.path, "-vn", "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", wav.path], log: log)
        status = "Transkribieren: \(src.lastPathComponent)"; progress = 0
        let threads = String(min(8, ProcessInfo.processInfo.activeProcessorCount))
        try await run(whisper, ["-m", model, "-f", wav.path, "-l", Prefs.shared.transcribeLang, "-t", threads,
                                "-np", "-pp", "-otxt", "-of", tmp.appendingPathComponent("out").path], log: log)

        let raw = try String(contentsOf: tmp.appendingPathComponent("out.txt"), encoding: .utf8)
        let text = raw.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n") + "\n"
        try fm.createDirectory(at: ShelfStore.ownDir, withIntermediateDirectories: true)
        let name = src.deletingPathExtension().lastPathComponent
        var dest = ShelfStore.ownDir.appendingPathComponent(name + ".txt")
        if fm.fileExists(atPath: dest.path) { dest = ShelfStore.ownDir.appendingPathComponent("\(name) \(Int(Date().timeIntervalSince1970)).txt") }
        try text.write(to: dest, atomically: true, encoding: .utf8)
        if Prefs.shared.transcribeCopy { copy(dest) }
        return dest
    }

    /// Startet ein Programm ohne Shell und wartet asynchron (Main-Thread bleibt frei). Abbruch der Task beendet den Prozess.
    private func run(_ exe: String, _ args: [String], log: URL) async throws {
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = try FileHandle(forWritingTo: log)  // Datei statt Pipe: kann nicht volllaufen
        try p.run()
        var text = ""
        while p.isRunning {
            if Task.isCancelled { p.terminate() }
            try? await Task.sleep(for: .milliseconds(300))
            text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            if let tail = text.components(separatedBy: "progress = ").dropFirst().last, let v = Double(tail.prefix { $0.isNumber }) { progress = v / 100 }
        }
        p.waitUntilExit()
        try Task.checkCancellation()
        text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        guard p.terminationStatus == 0 else {
            throw Fail("\(URL(fileURLWithPath: exe).lastPathComponent) fehlgeschlagen: " + (text.split(separator: "\n").last.map(String.init) ?? "Code \(p.terminationStatus)"))
        }
    }

    func copy(_ url: URL) {
        guard let t = try? String(contentsOf: url, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t, forType: .string)
    }

    func download(_ m: WhisperModel) {
        error = nil
        let task = URLSession.shared.downloadTask(with: m.url) { tmp, _, err in
            // Callback läuft im Hintergrund: hier prüfen und verschieben (die Temp-Datei verschwindet danach)
            let result = Result<Void, Error> {
                if let err { throw err }
                guard let tmp else { throw Fail("Download fehlgeschlagen") }
                try WhisperModel.verify(tmp, m)
                try FileManager.default.createDirectory(at: WhisperModel.dir, withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: m.local)
                try FileManager.default.moveItem(at: tmp, to: m.local)
            }
            Task { @MainActor in
                self.dl = nil; self.downloading = nil
                switch result {
                case .success: Prefs.shared.transcribeModel = m.local.path
                case .failure(let e as URLError) where e.code == .cancelled: break
                case .failure(let e): self.error = "Modell: \(e.localizedDescription)"
                }
            }
        }
        dl = task
        downloading = (m.file, 0)
        task.resume()
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
            Task { @MainActor in
                guard let d = self.dl, d === task else { timer.invalidate(); return }
                self.downloading = (m.file, d.progress.fractionCompleted)
            }
        }
    }

    func cancelDownload() { dl?.cancel() }

    /// Ablauf ohne Oberfläche prüfen: APPVOL_TRANSCRIBE=<Datei> (Modell aus den Einstellungen).
    /// APPVOL_TRANSCRIBE_CANCEL=<Sekunden> bricht nach dieser Zeit ab und prüft das Aufräumen.
    static func selfTest(_ path: String) {
        let t0 = Date()
        let task = Task { @MainActor in
            do {
                let out = try await shared.transcribe(URL(fileURLWithPath: path))
                print(String(format: "OK in %.1f s → %@\n", Date().timeIntervalSince(t0), out.path) + ((try? String(contentsOf: out, encoding: .utf8)) ?? ""))
                try? FileManager.default.removeItem(at: out)
                exit(0)
            } catch is CancellationError {
                print(String(format: "ABGEBROCHEN nach %.1f s", Date().timeIntervalSince(t0))); exit(0)
            } catch { print("FEHLER: \(error.localizedDescription)"); exit(1) }
        }
        if let s = ProcessInfo.processInfo.environment["APPVOL_TRANSCRIBE_CANCEL"].flatMap(Double.init) {
            Task { try? await Task.sleep(for: .seconds(s)); task.cancel() }
        }
    }
}

struct TranscribeView: View {
    @ObservedObject var t: Transcriber

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let s = t.status {
                Text(s).lineLimit(1).truncationMode(.middle)
                if let p = t.progress { ProgressView(value: p) } else { ProgressView().progressViewStyle(.linear) }
                HStack {
                    Text(t.progress.map { "\(Int($0 * 100)) %" } ?? "läuft …").monospacedDigit().foregroundStyle(.secondary)
                    if !t.queue.isEmpty { Text("· noch \(t.queue.count) in der Warteschlange").foregroundStyle(.secondary) }
                    Spacer()
                    Button("Abbrechen") { t.cancel() }
                }
            } else if !t.ready {
                Text("Noch nicht eingerichtet: ffmpeg, whisper-cli und ein Modell nötig (Einstellungen → Transkript).")
                    .foregroundStyle(.secondary)
            } else {
                VStack {
                    Image(systemName: "waveform.badge.mic").font(.title)
                    Text("Video oder Audio hierher ziehen")
                }
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 70)
            }
            if let u = t.last, t.status == nil {
                HStack {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: u.path)).resizable().frame(width: 24, height: 24)
                    Text(u.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Kopieren") { t.copy(u) }
                    Button("Im Finder") { NSWorkspace.shared.activateFileViewerSelecting([u]) }
                }
                .onDrag { NSItemProvider(object: u as NSURL) }
            }
            if let e = t.error { Text(e).font(.caption).foregroundStyle(.red).lineLimit(2) }
        }
    }
}

struct TranscribeSettings: View {
    @ObservedObject var prefs = Prefs.shared
    @ObservedObject var t = Transcriber.shared
    @State private var pick = WhisperModel.all[0]

    var body: some View {
        ForEach([("ffmpeg", "ffmpeg"), ("whisper-cli", "whisper-cpp")], id: \.0) { tool, formula in
            if let p = findTool(tool) {
                Label(p, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
            } else {
                Label("\(tool) fehlt – im Terminal: brew install \(formula)", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.orange).font(.caption).textSelection(.enabled)
            }
        }
        HStack {
            Picker("Modell", selection: $pick) { ForEach(WhisperModel.all) { Text($0.label).tag($0) } }
            if let d = t.downloading {
                ProgressView(value: d.fraction).frame(width: 80)
                Button("Abbrechen") { t.cancelDownload() }
            } else if FileManager.default.fileExists(atPath: pick.local.path) {
                Button("Verwenden") { prefs.transcribeModel = pick.local.path }
            } else {
                Button("Laden") { t.download(pick) }
            }
        }
        HStack {
            Text(prefs.transcribeModel.isEmpty ? "Kein Modell gewählt" : prefs.transcribeModel)
                .font(.caption).foregroundStyle(FileManager.default.fileExists(atPath: prefs.transcribeModel) ? Color.secondary : .orange)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            Button("Datei wählen …") {
                let p = NSOpenPanel()
                p.canChooseFiles = true; p.canChooseDirectories = false
                if p.runModal() == .OK, let u = p.url { prefs.transcribeModel = u.path }
            }
        }
        Picker("Sprache", selection: $prefs.transcribeLang) {
            ForEach([("auto", "Automatisch"), ("de", "Deutsch"), ("en", "Englisch"), ("fr", "Französisch"), ("es", "Spanisch"), ("it", "Italienisch")], id: \.0) {
                Text($0.1).tag($0.0)
            }
        }
        Toggle("Ergebnis zusätzlich in die Zwischenablage", isOn: $prefs.transcribeCopy)
        if let e = t.error { Text(e).font(.caption).foregroundStyle(.red) }
        Text("Video oder Audio auf die Notch ziehen, während der Tab Transkript offen ist. Alles läuft lokal. Das Transkript landet als .txt in der Ablage und wird mit ihr gelöscht.")
            .font(.caption).foregroundStyle(.secondary)
    }
}
