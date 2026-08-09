import Foundation

/// Self-tests for the parts the August 2026 audit found untested.
///
/// The 55 tests that existed covered frontmatter, slugs, blocks and date
/// buckets — all of which already worked. The four subsystems with no tests
/// at all were Supabase, the updater, the Keychain and the offline queue,
/// and every bug found that day was in those four. This closes the two that
/// are pure logic and need no network.
@MainActor
func runStateSelfTests() -> Bool {
    var ok = true
    func expect(_ cond: Bool, _ name: String) {
        print(cond ? "PASS  \(name)" : "FAIL  \(name)")
        if !cond { ok = false }
    }

    // ── LoadState: the distinction that cost an hour ────────────────────
    let never: LoadState<[Int]> = .never
    expect(!never.isConfirmedEmpty,
           "state: .never is NOT confirmed-empty — the whole point")
    expect(never.value == nil, "state: .never carries no value")

    let empty: LoadState<[Int]> = .loaded([], at: Date())
    expect(empty.isConfirmedEmpty,
           "state: .loaded([]) IS confirmed-empty")
    expect(empty.stamp != nil, "state: a loaded state carries its timestamp")

    var refreshing: LoadState<[Int]> = .loaded([1, 2, 3], at: Date())
    refreshing.beginLoading()
    expect(refreshing.value?.count == 3,
           "state: refreshing keeps the previous value on screen")
    expect(refreshing.isLoading, "state: refreshing reports loading")
    expect(!refreshing.isConfirmedEmpty,
           "state: a refreshing panel is never confirmed-empty")

    let failed: LoadState<[Int]> = .failed("403", at: Date())
    expect(failed.error == "403", "state: failure keeps its reason")
    expect(!failed.isConfirmedEmpty, "state: a failure is not an empty list")

    expect(never.provenance(source: "q").contains("not loaded"),
           "state: provenance says 'not loaded yet' before the first fetch")
    expect(empty.provenance(source: "q").contains("q ·"),
           "state: provenance names its source")

    // ── The clustering rule: three sources are a story, one is a rewrite ─
    func item(_ t: String, _ src: String) -> ReviewQueueItem {
        ReviewQueueItem(id: UUID().uuidString, title: t, source_url: nil, snippet: nil,
                        published_at: nil, relevance_score: nil, relevance_reason: nil,
                        status: "queued", created_at: nil, source_name: src,
                        source_slug: nil, region: nil)
    }
    let three = [item("Council adopts sanctions package on Belarus", "A"),
                 item("EU sanctions package targets Belarus banks", "B"),
                 item("Belarus sanctions: what the package covers", "C")]
    let clustered = DeskBuilder.clusters(three)
    expect(clustered.contains { $0.key == "belarus" && $0.items.count == 3 },
           "desk: three items on one subject form a cluster")

    let two = Array(three.prefix(2))
    expect(DeskBuilder.clusters(two).isEmpty,
           "desk: two items do NOT — a brief needs three sources")

    let noise = [item("Taylor Swift announces album", "A"),
                 item("Rain expected in Vienna", "B"),
                 item("Council adopts sanctions package", "C")]
    expect(!DeskBuilder.clusters(noise).contains { $0.items.count >= 3 },
           "desk: unrelated items do not cluster")

    // ── The updater's version comparison, which shipped untested ────────
    expect(UpdateChecker.isNewer("0.26.0", than: "0.25.0"), "update: 0.26.0 > 0.25.0")
    expect(!UpdateChecker.isNewer("0.25.0", than: "0.25.0"), "update: equal is not newer")
    expect(!UpdateChecker.isNewer("0.24.1", than: "0.25.0"),
           "update: an older release never downgrades a newer install")
    expect(UpdateChecker.isNewer("0.25.1", than: "0.25.0"), "update: patch bump counts")
    expect(UpdateChecker.isNewer("1.0.0", than: "0.99.99"), "update: major beats minor")
    expect(!UpdateChecker.isNewer("0.25", than: "0.25.0"),
           "update: a short version is not newer than its padded self")

    return ok
}
