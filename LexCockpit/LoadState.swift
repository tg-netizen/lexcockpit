import Foundation

/// What a panel knows about its own data.
///
/// Every fetch in this app used to carry three parallel fields — an array,
/// an error string, a loading flag — and that triple cannot express the one
/// state that matters most: *I have not asked yet*. An empty array reads as
/// "there is nothing", so on 9 August 2026 the Overview told its user the
/// waiting list was empty and to trigger a scan. Thirty-four items were
/// queued; Supabase had answered HTTP 200 with `[]` because the anon RLS
/// policies were missing. The app was not lying — it genuinely could not
/// tell the difference, because the shape of its own state made the
/// distinction unrepresentable.
///
/// Four cases, and every panel must be in exactly one of them.
enum LoadState<T> {
    /// Never asked. The honest state at launch, and the one that used to be
    /// indistinguishable from success.
    case never
    /// Asking now. Carries the previous value so a refresh does not blank
    /// the screen — the user keeps reading while the network works.
    case loading(previous: T?)
    /// Answered. The timestamp is not decoration: a count without a time is
    /// a claim without a date, which is the thing this whole project exists
    /// to avoid.
    case loaded(T, at: Date)
    /// Failed, with the reason kept for the user rather than for a log.
    case failed(String, at: Date)

    var value: T? {
        switch self {
        case .loaded(let v, _):    return v
        case .loading(let prev):   return prev
        case .never, .failed:      return nil
        }
    }

    var error: String? {
        if case .failed(let m, _) = self { return m }
        return nil
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    /// True only when we have actually asked and actually got nothing.
    /// `.never` is deliberately NOT empty — that is the whole point.
    var isConfirmedEmpty: Bool {
        guard case .loaded(let v, _) = self else { return false }
        if let c = v as? any Collection { return c.isEmpty }
        return false
    }

    var stamp: Date? {
        switch self {
        case .loaded(_, let d), .failed(_, let d): return d
        case .never, .loading:                     return nil
        }
    }

    /// One line of grey text for under a figure: where it came from and how
    /// old it is. The defence pages on the website put "read 5 Aug 2026"
    /// under every claim; this is the same habit, in an app.
    func provenance(source: String) -> String {
        switch self {
        case .never:
            return "\(source) · not loaded yet"
        case .loading:
            return "\(source) · checking…"
        case .failed(_, let at):
            return "\(source) · failed \(Self.ago(at))"
        case .loaded(_, let at):
            return "\(source) · \(Self.ago(at))"
        }
    }

    static func ago(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 10   { return "just now" }
        if s < 90   { return "\(s)s ago" }
        if s < 5400 { return "\(s / 60) min ago" }
        if s < 172800 { return "\(s / 3600) h ago" }
        return "\(s / 86400) d ago"
    }
}

extension LoadState {
    /// Start a refresh without throwing away what is on screen.
    mutating func beginLoading() { self = .loading(previous: value) }
}
