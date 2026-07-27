import SwiftUI
import AppKit

// MARK: - API diagnostics (what happened, when, how fast — tokens never logged)

struct DiagEntry: Identifiable {
    let id = UUID()
    let time: Date
    let service: String       // github / netlify / canva / feeds
    let detail: String        // METHOD path (no tokens, no bodies)
    let status: String        // "200" / "409" / "offline" / …
    let ms: Int
    let ok: Bool
}

@MainActor
final class Diagnostics: ObservableObject {
    static let shared = Diagnostics()
    @Published private(set) var entries: [DiagEntry] = []

    func append(_ e: DiagEntry) {
        entries.insert(e, at: 0)
        if entries.count > 200 { entries.removeLast(entries.count - 200) }
    }

    var report: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        var out = "LexCockpit \(AppVersion.current) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        out += "Queue: \(CommitQueue.shared.items.count) pending · Radar unseen: \(RadarStore.shared.unseenCount)\n"
        out += String(repeating: "─", count: 60) + "\n"
        for e in entries.prefix(80) {
            out += "\(f.string(from: e.time))  \(e.ok ? "✓" : "✗")  \(e.service.padding(toLength: 8, withPad: " ", startingAt: 0))  \(e.status.padding(toLength: 8, withPad: " ", startingAt: 0))  \(e.ms) ms  \(e.detail)\n"
        }
        return out
    }
}

/// Thread-safe recorder callable from any (nonisolated) API code path.
func diagRecord(_ service: String, _ detail: String, status: String, start: Date, ok: Bool) {
    let ms = Int(Date().timeIntervalSince(start) * 1000)
    Task { @MainActor in
        Diagnostics.shared.append(DiagEntry(time: Date(), service: service,
                                            detail: detail, status: status, ms: ms, ok: ok))
    }
}

// MARK: - Sheet

struct DiagnosticsSheet: View {
    @ObservedObject private var diag = Diagnostics.shared
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Diagnostics").font(.system(size: 14, weight: .semibold))
                Text("· last \(diag.entries.count) API calls — no tokens, no content")
                    .font(.caption).foregroundColor(.textSecondary)
                Spacer()
                Button(copied ? "Copied ✓" : "Copy diagnostics") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(diag.report, forType: .string)
                    copied = true
                }
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            if diag.entries.isEmpty {
                Spacer()
                Text("No API calls recorded yet in this session.")
                    .font(.callout).foregroundColor(.textSecondary)
                Spacer()
            } else {
                List(diag.entries) { e in
                    HStack(spacing: 8) {
                        Image(systemName: e.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundColor(e.ok ? .statusGreen : .statusRed)
                            .font(.system(size: 11))
                        Text(e.service).font(.system(size: 11, weight: .semibold))
                            .frame(width: 52, alignment: .leading)
                        Text(e.detail).font(.system(size: 11, design: .monospaced))
                            .lineLimit(1).foregroundColor(.textPrimary)
                        Spacer()
                        Text(e.status).font(.system(size: 11, design: .monospaced))
                            .foregroundColor(e.ok ? .textSecondary : .statusRed)
                        Text("\(e.ms) ms").font(.system(size: 11))
                            .foregroundColor(.textSecondary).frame(width: 58, alignment: .trailing)
                        Text(relativeTime(ISO8601DateFormatter().string(from: e.time)))
                            .font(.system(size: 10)).foregroundColor(.textSecondary)
                            .frame(width: 64, alignment: .trailing)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 720, height: 440)
    }
}
