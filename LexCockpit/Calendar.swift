import SwiftUI
import AppKit

// MARK: - Editorial calendar (the newsroom heart)
//
// Month grid of everything published and scheduled; unscheduled drafts sit
// in a tray and can be DRAGGED onto a day — the drop writes
// scheduled_publish_at through the normal commit path (the site's daily
// build flips the article live on that date).

struct CalendarTabView: View {
    @ObservedObject var model: WorkspaceModel
    var openArticle: (ContentEntry) -> Void

    @State private var monthAnchor = Date()
    @State private var savingPaths: Set<String> = []
    @State private var errorText: String?

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2                      // Monday (EU newsroom)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let err = errorText {
                HStack {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundColor(.statusRed)
                    Spacer()
                    Button("OK") { errorText = nil }.controlSize(.small)
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
                Divider()
            }
            draftsTray
            Divider()
            monthGrid
        }
        .background(Color.bgPage)
        .task { if model.contentEntries.isEmpty { await model.loadContentList() } }
    }

    // MARK: header

    private var monthTitle: String {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f.string(from: monthAnchor)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Editorial calendar")
                .font(.system(size: 15, weight: .bold)).foregroundColor(.textPrimary)
            Spacer()
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }
            Button("Today") { monthAnchor = Date() }
            Button { shift(1) } label: { Image(systemName: "chevron.right") }
            Text(monthTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.accentNavy)
                .frame(width: 130, alignment: .leading)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.bgCard)
    }

    private func shift(_ months: Int) {
        monthAnchor = cal.date(byAdding: .month, value: months, to: monthAnchor) ?? monthAnchor
    }

    // MARK: drafts tray (drag sources)

    private var unscheduledDrafts: [ContentEntry] {
        model.contentEntries.filter { $0.isDraft && $0.scheduled.isEmpty }
    }

    private var draftsTray: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DRAFTS — drag onto a day to schedule")
                .font(.system(size: 10, weight: .semibold)).tracking(0.5)
                .foregroundColor(.textSecondary)
            if unscheduledDrafts.isEmpty {
                Text("No unscheduled drafts.").font(.caption).foregroundColor(.textSecondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(unscheduledDrafts) { entry in
                            chip(entry, color: .accentNavy)
                                .draggable(entry.path)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color.bgCard)
    }

    // MARK: month grid

    private var monthDays: [String?] {
        guard let interval = cal.dateInterval(of: .month, for: monthAnchor) else { return [] }
        let first = interval.start
        let daysInMonth = cal.range(of: .day, in: .month, for: monthAnchor)?.count ?? 30
        let weekdayOfFirst = cal.component(.weekday, from: first)          // 1=Sun…
        let leading = (weekdayOfFirst - cal.firstWeekday + 7) % 7
        var cells: [String?] = Array(repeating: nil, count: leading)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        for day in 0..<daysInMonth {
            if let date = cal.date(byAdding: .day, value: day, to: first) {
                cells.append(f.string(from: date))
            }
        }
        while cells.count % 7 != 0 { cells.append(nil) }
        return cells
    }

    private func entries(on iso: String) -> [ContentEntry] {
        model.contentEntries.filter { entry in
            if entry.scheduled == iso { return true }
            if entry.status == "published" && entry.date == iso { return true }
            return false
        }
    }

    private var monthGrid: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"], id: \.self) { day in
                    Text(day).font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.textSecondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 6)
            Divider()
            GeometryReader { geo in
                let cells = monthDays
                let rows = max(1, cells.count / 7)
                let cellH = geo.size.height / CGFloat(rows)
                VStack(spacing: 0) {
                    ForEach(0..<rows, id: \.self) { row in
                        HStack(spacing: 0) {
                            ForEach(0..<7, id: \.self) { col in
                                let idx = row * 7 + col
                                dayCell(cells.indices.contains(idx) ? cells[idx] : nil)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: cellH)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func dayCell(_ iso: String?) -> some View {
        if let iso = iso {
            let today = iso == todayISO()
            VStack(alignment: .leading, spacing: 3) {
                Text(String(iso.suffix(2)))
                    .font(.system(size: 11, weight: today ? .bold : .regular))
                    .foregroundColor(today ? .white : .textSecondary)
                    .padding(4)
                    .background(Circle().fill(today ? Color.accentNavy : .clear))
                ForEach(entries(on: iso).prefix(3)) { entry in
                    chip(entry, color: entry.status == "published" ? .statusGreen : .statusAmber)
                }
                if entries(on: iso).count > 3 {
                    Text("+\(entries(on: iso).count - 3) more")
                        .font(.system(size: 9)).foregroundColor(.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(savingPaths.isEmpty ? Color.clear : Color.clear)
            .overlay(Rectangle().stroke(Color.cardBorder.opacity(0.6), lineWidth: 0.5))
            .dropDestination(for: String.self) { paths, _ in
                guard let path = paths.first else { return false }
                Task { await schedule(path: path, on: iso) }
                return true
            }
        } else {
            Rectangle().fill(Color.bgCard.opacity(0.4))
                .overlay(Rectangle().stroke(Color.cardBorder.opacity(0.4), lineWidth: 0.5))
        }
    }

    private func chip(_ entry: ContentEntry, color: Color) -> some View {
        Button {
            openArticle(entry)
        } label: {
            HStack(spacing: 4) {
                if savingPaths.contains(entry.path) {
                    ProgressView().controlSize(.mini)
                } else {
                    Circle().fill(color).frame(width: 6, height: 6)
                }
                Text(entry.title)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(.textPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(color.opacity(0.12)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(entry.title)
    }

    // MARK: schedule-by-drop (normal commit path)

    private func schedule(path: String, on iso: String) async {
        guard let repo = model.site.repo else { return }
        savingPaths.insert(path)
        defer { savingPaths.remove(path) }
        // If this article is open and dirty, schedule through the open doc.
        if let open = model.editor, open.repoPath == path {
            open.schedule(iso)
            await open.save(repo: repo, message: "content: schedule \(open.slug) for \(iso)")
        } else {
            do {
                let f = try await GitHubAPI.file(repo: repo, path: path)
                guard let text = f.decodedText() else { return }
                let doc = EditorDocument(repoPath: path, text: text, sha: f.sha, isNew: false)
                doc.schedule(iso)
                await doc.save(repo: repo, message: "content: schedule \(doc.slug) for \(iso)")
                if doc.conflict {
                    errorText = "Scheduling conflicted with a newer version of \(doc.fileName) — open it and retry."
                    return
                }
            } catch {
                errorText = error.localizedDescription
                return
            }
        }
        await model.loadContentList()
    }
}
