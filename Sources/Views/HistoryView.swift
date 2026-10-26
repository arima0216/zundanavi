import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var history: HistoryStore

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M/d HH:mm"
        return f
    }()

    var body: some View {
        NavigationStack {
            List {
                if history.entries.isEmpty {
                    Text("まだ会話が無いのだ")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(history.entries.reversed())) { e in
                    Button {
                        model.replay(e)
                    } label: {
                        row(e)
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
            .navigationTitle("履歴")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable {
                await model.refreshHistory()
            }
            .task {
                await model.refreshHistory()
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("消去", role: .destructive) {
                        history.clear()
                    }
                }
            }
        }
    }

    private func roleLabel(_ role: String) -> String {
        switch role {
        case "user": return "もも"
        case "assistant": return "ずんだもん"
        case "push": return "お知らせ"
        default: return role
        }
    }

    private func roleColor(_ role: String) -> Color {
        switch role {
        case "user": return .blue
        case "assistant": return Color(red: 0.30, green: 0.69, blue: 0.31)
        case "push": return .orange
        default: return .gray
        }
    }

    private func row(_ e: HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(roleLabel(e.role))
                    .font(.caption.bold())
                    .foregroundColor(roleColor(e.role))
                Text(HistoryView.timeFormatter.string(from: e.ts))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if e.source == "server" {
                    Text("サーバー")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if e.audioURL != nil {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(e.text)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
