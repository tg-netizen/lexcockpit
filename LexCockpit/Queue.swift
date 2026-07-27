import Foundation
import SwiftUI

// MARK: - Offline commit queue (write on the train, publish when back)

struct QueuedCommit: Codable, Identifiable {
    let id: String
    let repo: String
    let path: String
    let message: String
    let text: String
    let sha: String?          // baseline at queue time (nil = new file)
    let queuedAt: Date
    var conflicted = false
}

/// Failed-for-network saves land here and are pushed automatically when the
/// connection returns (launch, every 60 s, or manual flush). SHA conflicts
/// during flush are surfaced, never overwritten.
@MainActor
final class CommitQueue: ObservableObject {
    static let shared = CommitQueue()

    @Published private(set) var items: [QueuedCommit] = []
    @Published var flushing = false
    @Published var lastResult: String?

    private static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LexCockpit/commit-queue.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.file),
           let saved = try? JSONDecoder().decode([QueuedCommit].self, from: data) {
            items = saved
        }
    }

    private func persist() {
        try? FileManager.default.createDirectory(
            at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: Self.file) }
    }

    func enqueue(repo: String, path: String, message: String, text: String, sha: String?) {
        // one queued commit per file — newer content replaces older
        items.removeAll { $0.path == path }
        items.append(QueuedCommit(id: UUID().uuidString, repo: repo, path: path,
                                  message: message, text: text, sha: sha, queuedAt: Date()))
        persist()
    }

    func pending(for path: String) -> QueuedCommit? {
        items.first { $0.path == path }
    }

    /// Push everything that isn't conflicted. Returns commits landed.
    @discardableResult
    func flush() async -> Int {
        guard !items.isEmpty, !flushing else { return 0 }
        flushing = true
        defer { flushing = false }
        var landed = 0
        for var item in items where !item.conflicted {
            do {
                let resp = try await GitHubAPI.put(repo: item.repo, path: item.path,
                                                   message: item.message,
                                                   text: item.text, sha: item.sha)
                items.removeAll { $0.id == item.id }
                landed += 1
                lastResult = "Queued commit landed: \(String(resp.commit.sha.prefix(7)))"
            } catch APIError.conflict {
                item.conflicted = true
                if let idx = items.firstIndex(where: { $0.id == item.id }) { items[idx] = item }
                lastResult = "Queued commit for \((item.path as NSString).lastPathComponent) conflicts — open the article to resolve."
            } catch {
                break                     // still offline — try again later
            }
        }
        persist()
        return landed
    }

    func discard(_ id: String) {
        items.removeAll { $0.id == id }
        persist()
    }
}

// MARK: - Local version snapshots (every save, browsable offline)

enum Snapshots {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LexCockpit/snapshots", isDirectory: true)
    }

    static func record(slug: String, text: String) {
        let dir = root.appendingPathComponent(slug, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let url = dir.appendingPathComponent(f.string(from: Date()) + ".md")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        prune(dir: dir, keep: 30)
    }

    static func list(slug: String) -> [(url: URL, date: Date, words: Int)] {
        let dir = root.appendingPathComponent(slug, isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        return files
            .filter { $0.pathExtension == "md" }
            .compactMap { url in
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? Date.distantPast
                let words = (try? String(contentsOf: url, encoding: .utf8))
                    .map { $0.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count } ?? 0
                return (url, date, words)
            }
            .sorted { $0.date > $1.date }
    }

    private static func prune(dir: URL, keep: Int) {
        let all = list(slug: dir.lastPathComponent)
        for old in all.dropFirst(keep) {
            try? FileManager.default.removeItem(at: old.url)
        }
    }
}

// MARK: - History sheet

struct SnapshotHistorySheet: View {
    let slug: String
    var restore: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var snapshots: [(url: URL, date: Date, words: Int)] = []
    @State private var selected: URL?
    @State private var previewText = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Local history — \(slug)").font(.system(size: 14, weight: .semibold))
                Text("· every save, kept on this Mac").font(.caption).foregroundColor(.textSecondary)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            HSplitView {
                List(snapshots, id: \.url, selection: $selected) { snap in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(relativeTime(ISO8601DateFormatter().string(from: snap.date)))
                            .font(.system(size: 12, weight: .medium))
                        Text("\(snap.words) words").font(.caption2).foregroundColor(.textSecondary)
                    }
                    .tag(snap.url)
                }
                .frame(minWidth: 170, maxWidth: 220)
                VStack(spacing: 0) {
                    ScrollView {
                        Text(previewText.isEmpty ? "Select a snapshot." : previewText)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .textSelection(.enabled)
                    }
                    Divider()
                    HStack {
                        Spacer()
                        Button("Restore this version") {
                            if !previewText.isEmpty { restore(previewText); dismiss() }
                        }
                        .buttonStyle(.borderedProminent).tint(.accentNavy)
                        .disabled(previewText.isEmpty)
                    }
                    .padding(10)
                }
            }
        }
        .frame(width: 700, height: 460)
        .onAppear { snapshots = Snapshots.list(slug: slug) }
        .onChange(of: selected) { url in
            previewText = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        }
    }
}
