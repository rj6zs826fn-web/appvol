// Liest den Status aller Claude-Code-Sitzungen für die Notch.
// Quelle 1: Statusdateien des Hooks claude-status-hook.py (arbeitet / wartet / fertig).
// Quelle 2: Sitzungsdateien der Claude-Desktop-App (Titel, local_-ID für den Direktlink, „wartet auf dich“).

import AppKit

struct ClaudeSession: Identifiable, Equatable {
    enum State: String { case working, waiting, done }
    let id: String
    var state: State
    var title: String
    var detail: String
    var updated: Date
    var localId: String?
    var needsInput: Bool    // Rückfrage oder Freigabe nötig

    var openURL: URL? {
        localId.flatMap { URL(string: "claude://code/continue?session=\($0)") }
    }
}

final class ClaudeMonitor {
    private struct DesktopInfo { let localId: String; let title: String; let blocked: Bool; let action: String; let summary: String }

    private let fm = FileManager.default
    private let home = FileManager.default.homeDirectoryForCurrentUser
    // APPVOL_CLAUDE_DIR: andere Statusdateien, z.B. zum Testen
    private lazy var statusDir = ProcessInfo.processInfo.environment["APPVOL_CLAUDE_DIR"].map { URL(fileURLWithPath: $0) }
        ?? home.appendingPathComponent("Library/Application Support/AppVol/claude")
    private lazy var desktopDir = home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
    private var desktopCache: [String: (mtime: Date, info: DesktopInfo, cli: [String])] = [:]
    private var dismissed: Set<String> = []

    /// Merkt sich eine fertige Sitzung als gesehen, bis sie wieder etwas Neues meldet.
    func dismiss(_ s: ClaudeSession) { dismissed.insert(key(s)) }
    private func key(_ s: ClaudeSession) -> String { "\(s.id)@\(s.updated.timeIntervalSince1970)" }

    func load() -> [ClaudeSession] {
        let byCli = desktopIndex()
        let now = Date()
        var out: [ClaudeSession] = []
        for f in (try? fm.contentsOfDirectory(at: statusDir, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "json" {
            guard let d = try? JSONSerialization.jsonObject(with: Data(contentsOf: f)) as? [String: Any],
                  let sid = d["session_id"] as? String,
                  let state = ClaudeSession.State(rawValue: d["state"] as? String ?? "") else { continue }
            let updated = Date(timeIntervalSince1970: d["updated"] as? Double ?? 0)
            let age = now.timeIntervalSince(updated)
            // Hängengebliebene oder alte Sitzungen ausblenden
            if age > (state == .done ? 30 * 60 : 3 * 3600) { continue }
            let desk = byCli[sid]
            let folder = (d["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
            let prompt = d["prompt"] as? String ?? ""
            let blocked = state == .done && (desk?.blocked ?? false)
            let detail: String
            switch state {
            case .working: detail = desk == nil || prompt.isEmpty ? "arbeitet …" : prompt  // ohne Desktop-Titel ist der Auftrag schon der Titel
            case .waiting: detail = (d["message"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "wartet auf dich"
            case .done: detail = blocked ? (desk?.action ?? "") : (desk?.summary ?? "fertig")
            }
            var s = ClaudeSession(id: sid, state: state,
                                  title: desk?.title ?? (prompt.isEmpty ? folder : prompt),
                                  detail: detail, updated: updated, localId: desk?.localId,
                                  needsInput: state == .waiting || blocked)
            if s.title.isEmpty { s.title = "Claude" }
            if state == .done, dismissed.contains(key(s)) { continue }
            out.append(s)
        }
        // Dringendes zuerst: Rückfrage, dann arbeitet, dann fertig
        func rank(_ s: ClaudeSession) -> Int { s.needsInput ? 0 : s.state == .working ? 1 : 2 }
        return out.sorted { (rank($0), -$0.updated.timeIntervalSince1970) < (rank($1), -$1.updated.timeIntervalSince1970) }
    }

    /// cliSessionId → Infos der Desktop-App; liest nur geänderte Dateien neu.
    private func desktopIndex() -> [String: DesktopInfo] {
        var index: [String: DesktopInfo] = [:]
        guard let e = fm.enumerator(at: desktopDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return index }
        for case let f as URL in e where f.lastPathComponent.hasPrefix("local_") && f.pathExtension == "json" {
            let mtime = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if desktopCache[f.path]?.mtime != mtime {
                // shortcut: internes Dateiformat der Claude-App – ändert es sich, fehlen nur Titel/Direktlink, Status geht weiter
                guard let d = try? JSONSerialization.jsonObject(with: Data(contentsOf: f)) as? [String: Any],
                      let local = d["sessionId"] as? String, d["isArchived"] as? Bool != true else {
                    // unlesbar oder archiviert: merken, damit die Datei nicht jede Sekunde neu gelesen wird
                    desktopCache[f.path] = (mtime, DesktopInfo(localId: "", title: "", blocked: false, action: "", summary: ""), [])
                    continue
                }
                let sum = d["postTurnSummary"] as? [String: Any] ?? [:]
                let info = DesktopInfo(localId: local, title: d["title"] as? String ?? "",
                                       blocked: sum["status_category"] as? String == "blocked",
                                       action: sum["needs_action"] as? String ?? "",
                                       summary: (d["turnWrapUp"] as? [String: Any])?["description"] as? String ?? sum["status_detail"] as? String ?? "fertig")
                let cli = [d["cliSessionId"], d["lastAssistantCliSessionId"]].compactMap { $0 as? String }
                desktopCache[f.path] = (mtime, info, cli)
            }
            if let c = desktopCache[f.path] { for id in c.cli { index[id] = c.info } }
        }
        return index
    }
}
