import SwiftUI

struct ConsoleView: View {
    @Bindable var log: ConsoleLog
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            if isExpanded {
                Divider()
                logList
            }
        }
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                        .font(.caption.bold())
                    Image(systemName: "terminal")
                        .font(.caption)
                    Text("Console")
                        .font(.caption).bold()
                    if !log.entries.isEmpty {
                        Text("(\(log.entries.count))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let last = log.entries.last, !isExpanded {
                        Text("·")
                            .foregroundStyle(.secondary)
                        Text(last.message)
                            .font(.caption)
                            .foregroundStyle(last.level.color)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            if isExpanded {
                Button {
                    let text = log.entries.map {
                        "[\($0.formattedTimestamp)] \($0.message)"
                    }.joined(separator: "\n")
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(text, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy all log entries")
                .disabled(log.entries.isEmpty)

                Button {
                    log.clear()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Clear console")
                .disabled(log.entries.isEmpty)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if log.entries.isEmpty {
                        Text("No output yet")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(8)
                    } else {
                        ForEach(log.entries) { entry in
                            logRow(entry)
                                .id(entry.id)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 180)
            .background(Color.black.opacity(0.25))
            .onChange(of: log.entries.count) { _, _ in
                if let last = log.entries.last {
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onAppear {
                if let last = log.entries.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private func logRow(_ entry: LogEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(entry.formattedTimestamp)
                .foregroundStyle(.secondary)
            Text(entry.level.symbol)
                .foregroundStyle(entry.level.color)
                .frame(width: 12)
            Text(entry.message)
                .foregroundStyle(entry.level.color)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.system(.caption, design: .monospaced))
    }
}
