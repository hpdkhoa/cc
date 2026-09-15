import SwiftUI
import AppKit
import DecanterCore

/// Live view of `Log.shared`: every command, its env diff, and every output line.
@MainActor struct LogConsoleView: View {
    var title: String = "Logs"

    @State private var entries: [LogEntry] = []
    @State private var filter = ""
    @State private var autoscroll = true

    private static let timeFormat: Date.FormatStyle = .dateTime.hour(.twoDigits(amPM: .omitted)).minute().second()

    private var visible: [LogEntry] {
        guard !filter.isEmpty else { return entries }
        return entries.filter { $0.message.localizedCaseInsensitiveContains(filter) || $0.source.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                TextField("Filter", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                Toggle("Follow", isOn: $autoscroll).toggleStyle(.checkbox)
                Button("Copy") { copyAll() }
                Button("Clear") { Log.shared.clear(); entries.removeAll() }
            }
            .padding(8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(visible) { e in
                            HStack(alignment: .top, spacing: 6) {
                                Text(e.date, format: Self.timeFormat).foregroundStyle(.tertiary)
                                Text(e.source).foregroundStyle(.secondary).frame(width: 90, alignment: .leading).lineLimit(1)
                                Text(e.message).foregroundStyle(color(for: e.level)).textSelection(.enabled)
                            }
                            .font(.system(.caption, design: .monospaced))
                            .id(e.id)
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: entries.last?.id) { _, _ in   // not .count: the buffer is capped
                    if autoscroll, let last = visible.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .background(.background)
        .task {
            entries = []
            for await entry in Log.shared.stream(includingHistory: true) {
                entries.append(entry)
                if entries.count > 5000 { entries.removeFirst(entries.count - 5000) }
            }
        }
    }

    private func color(for level: LogEntry.Level) -> Color {
        switch level {
        case .info: return .secondary
        case .command: return .blue
        case .output: return .primary
        case .error: return .red
        }
    }

    private func copyAll() {
        let text = visible.map { "[\($0.source)] \($0.message)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
