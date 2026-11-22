// Liest den Status aller Claude-Code-Sitzungen für die Notch.
// Quelle 1: Statusdateien des Hooks claude-status-hook.py (arbeitet / wartet / fertig).
// Quelle 2: Sitzungsdateien der Claude-Desktop-App (Titel, local_-ID für den Direktlink, „wartet auf dich“).
// Dazu: Freigabe-Anfragen des Hooks (permissions/) und Nutzung aus der statusLine (usage.json).

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

/// Offene Freigabe-Anfrage aus dem PermissionRequest-Hook.
struct ClaudePermission: Identifiable, Equatable {
    let id: String
    let tool: String
    let summary: String
    let folder: String
    let created: Date
}

/// Rate-Limits aus der offiziellen statusLine-Eingabe (rate_limits.five_hour / seven_day).
struct ClaudeUsage: Equatable {
    struct Window: Equatable { let percent: Double; let resets: Date }
    var fiveHour: Window?
    var sevenDay: Window?
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
    private lazy var permDir = statusDir.appendingPathComponent("permissions")
    private var lastAlive = Date.distantPast

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

    // ---------- Freigaben ----------

    /// Lebenszeichen für den Hook: nur solange es frisch ist, wartet er auf die Notch.
    func heartbeat(_ on: Bool) {
        let alive = permDir.appendingPathComponent(".alive")
        guard on else {
            if lastAlive != .distantPast { try? fm.removeItem(at: alive); lastAlive = .distantPast }
            return
        }
        guard Date().timeIntervalSince(lastAlive) > 4 else { return }
        try? fm.createDirectory(at: permDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: permDir.path)  // falls schon da, aber offen
        if !fm.fileExists(atPath: alive.path) { fm.createFile(atPath: alive.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: alive.path)
        lastAlive = Date()
    }

    func permissions() -> [ClaudePermission] {
        let now = Date()
        return ((try? fm.contentsOfDirectory(at: permDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasSuffix(".req.json") }
            .compactMap { f -> ClaudePermission? in
                guard let d = try? JSONSerialization.jsonObject(with: Data(contentsOf: f)) as? [String: Any],
                      let id = d["id"] as? String, ClaudeSetup.isRequestId(id),
                      f.lastPathComponent == "\(id).req.json" else { return nil }
                let created = Date(timeIntervalSince1970: d["created"] as? Double ?? 0)
                guard now.timeIntervalSince(created) < 75 else { return nil }  // Hook wartet höchstens 60 s
                return ClaudePermission(id: id, tool: d["tool"] as? String ?? "?", summary: d["summary"] as? String ?? "",
                                        folder: (d["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "",
                                        created: created)
            }
            .sorted { $0.created < $1.created }
    }

    func answer(_ p: ClaudePermission, allow: Bool) {
        try? ClaudeSetup.writeAnswer(dir: permDir, id: p.id, allow: allow)
    }

    // ---------- Nutzung ----------

    func usage() -> ClaudeUsage? {
        guard let d = try? JSONSerialization.jsonObject(with: Data(contentsOf: statusDir.appendingPathComponent("usage.json"))) as? [String: Any],
              let rl = d["rate_limits"] as? [String: Any] else { return nil }
        func window(_ k: String) -> ClaudeUsage.Window? {
            guard let w = rl[k] as? [String: Any], let p = w["used_percentage"] as? Double,
                  let r = w["resets_at"] as? Double, r > Date().timeIntervalSince1970 else { return nil }  // abgelaufen = unbekannt
            return .init(percent: p, resets: Date(timeIntervalSince1970: r))
        }
        let u = ClaudeUsage(fiveHour: window("five_hour"), sevenDay: window("seven_day"))
        return u.fiveHour == nil && u.sevenDay == nil ? nil : u
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
