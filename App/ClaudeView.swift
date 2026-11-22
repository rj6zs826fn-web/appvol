// Claude-Tab: Liste aller Claude-Code-Sitzungen, Klick springt in den Chat.

import SwiftUI

struct ClaudeListView: View {
    @ObservedObject var state: AppState

    var body: some View {
        Group {
            if state.claude.isEmpty {
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

}

struct ClaudeSettings: View {
    var body: some View {
        Text("Braucht die Status-Hooks in ~/.claude/settings.json – Anleitung: README, Abschnitt „Claude-Status einrichten“.")
            .font(.caption).foregroundStyle(.secondary)
    }
}
