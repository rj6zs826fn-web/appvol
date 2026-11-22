// Claude-Tab: Liste aller Claude-Code-Sitzungen, Klick springt in den Chat.
// Dazu Freigaben (Erlauben/Ablehnen), Nutzung (5-h-/7-Tage-Limit) und die Einrichtung per Knopf.

import SwiftUI

struct ClaudeListView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let u = state.claudeUsage { usage(u) }
            ForEach(state.claudePermissions) { permission($0) }
            if state.claude.isEmpty && state.claudePermissions.isEmpty {
                Text("Keine aktiven Claude-Sitzungen.").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(state.claude) { s in
                            Button { state.openClaude(s) } label: {
                                HStack(spacing: 10) {
                                    Group {
                                        if s.needsInput { Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange) }
                                        else if s.state == .working { ProgressView().controlSize(.small) }
                                        else { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                                    }
                                    .frame(width: 18)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(s.title).fontWeight(.semibold).lineLimit(1)
                                        Text(s.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    Text(s.updated, style: .relative).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                                }
                                .padding(.vertical, 4).padding(.horizontal, 6)
                                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(s.localId == nil ? "Claude öffnen" : "Zum Chat springen")
                        }
                    }
                }
            }
        }
    }

    private func usage(_ u: ClaudeUsage) -> some View {
        HStack(spacing: 12) {
            if let w = u.fiveHour { limit("5-h-Limit", w) }
            if let w = u.sevenDay { limit("7-Tage-Limit", w) }
            Spacer()
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    private func limit(_ name: String, _ w: ClaudeUsage.Window) -> some View {
        Text("\(name) \(Int(w.percent.rounded())) %")
            .foregroundStyle(w.percent >= 90 ? .red : w.percent >= 70 ? .orange : .secondary)
            .monospacedDigit()
            .help("Zurückgesetzt \(w.resets.formatted(date: .omitted, time: .shortened))")
    }

    private func permission(_ p: ClaudePermission) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield.fill").foregroundStyle(.orange).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(p.tool)\(p.folder.isEmpty ? "" : " · \(p.folder)")").fontWeight(.semibold).lineLimit(1)
                Text(p.summary.isEmpty ? "möchte ein Werkzeug benutzen" : p.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button("Ablehnen") { state.answerClaude(p, allow: false) }
            Button("Erlauben") { state.answerClaude(p, allow: true) }.keyboardShortcut(.defaultAction)
        }
        .padding(6)
        .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Claude-Freigabe: \(p.tool)")
    }
}

extension AppState {
    /// Freigaben und Nutzung; läuft nach jedem refreshClaude.
    func refreshClaudeExtras() {
        let on = prefs.isOn(.claude)
        monitor.heartbeat(on && prefs.claudePermissions)
        let perms = on && prefs.claudePermissions ? monitor.permissions() : []
        if perms != claudePermissions {
            if perms.contains(where: { !claudePermissions.contains($0) }) { popup(.claude, seconds: 60) }
            claudePermissions = perms
        }
        // Offene Anfrage: Notch bleibt offen, bis der Hook aufgibt – auch wenn ein anderes Aufploppen kürzer war
        if let until = popupUntil, let last = perms.last {
            popupUntil = max(until, last.created.addingTimeInterval(60))
        }
        let u = on && prefs.claudeUsage ? monitor.usage() : nil
        if u != claudeUsage { claudeUsage = u }
    }

    /// Nur auf Klick: einmal erlauben oder ablehnen, nie dauerhafte Regeln.
    func answerClaude(_ p: ClaudePermission, allow: Bool) {
        monitor.answer(p, allow: allow)
        claudePermissions.removeAll { $0 == p }
        if claudePermissions.isEmpty { popupUntil = nil; expanded = false }
    }
}

struct ClaudeSettings: View {
    @ObservedObject var prefs = Prefs.shared
    @State private var hooks = false
    @State private var statusLine = ClaudeSetup.StatusLine.none
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(hooks ? "Claude-Status eingerichtet" : "Claude-Status nicht eingerichtet",
                      systemImage: hooks ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(hooks ? .green : .orange)
                Spacer()
                Button(hooks ? "Neu einrichten" : "Claude-Status einrichten") { run(ClaudeSetup.installHooks) }
                if hooks { Button("Entfernen") { run(ClaudeSetup.uninstallHooks) } }
            }
            Toggle(isOn: $prefs.claudePermissions) {
                VStack(alignment: .leading) {
                    Text("Freigaben in der Notch")
                    Text("Fragt Claude nach einer Freigabe, klappt die Notch mit Erlauben/Ablehnen auf (nur einmalig). Ohne Antwort nach 60 s kommt Claudes normaler Dialog.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: $prefs.claudeUsage) {
                VStack(alignment: .leading) {
                    Text("Nutzung anzeigen")
                    Text("5-h- und 7-Tage-Limit im Claude-Tab (Pro/Max). Braucht die statusLine; zählt nur Sitzungen im Terminal.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if prefs.claudeUsage {
                HStack {
                    Text(statusLine == .ours ? "statusLine eingerichtet" : statusLine == .foreign ? "eigene statusLine vorhanden" : "statusLine nicht eingerichtet")
                        .font(.caption).foregroundStyle(statusLine == .ours ? .green : .orange)
                    Spacer()
                    if statusLine == .ours { Button("statusLine entfernen") { run(ClaudeSetup.uninstallStatusLine) } }
                    else { Button("statusLine einrichten") { run(ClaudeSetup.installStatusLine) } }
                }
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        let s = (try? ClaudeSetup.read()) ?? [:]
        hooks = ClaudeSetup.hooksInstalled(s)
        statusLine = ClaudeSetup.statusLineState(s)
    }

    private func run(_ action: () throws -> Void) {
        do { try action(); message = "Gespeichert in \(ClaudeSetup.settingsURL.path) (Sicherungskopie daneben). Gilt für neue Claude-Sitzungen." }
        catch { message = error.localizedDescription }
        reload()
    }
}
