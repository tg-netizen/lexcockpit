import SwiftUI

/*  WireTab.swift — what came in from outside
 *  ═══════════════════════════════════════════════════════════════════
 *  The scan that watches the outside world used to sit at the bottom of
 *  the project Overview, under the article library. That put it below
 *  the writing, as though it were an appendix to it. It is the opposite:
 *  it is what happened before anything was written, and on most days it
 *  is the first thing worth looking at.
 *
 *  So it has its own place now, in the News group, next to the articles
 *  rather than inside them. Nothing about the data changed; only where
 *  the eye finds it.
 */

struct WireTabView: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                waitingListSection
            }
            .padding(20)
        }
        .background(Color.bgPage)
        .task { await model.loadReviewQueue() }
    }

    @ViewBuilder private var waitingListSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("News waiting list")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.textPrimary)
                Spacer()
                if model.reviewQueueLoading { ProgressView().controlSize(.small) }
                /* Provenance, not decoration. A count without a time is a
                   claim without a date, which is the thing this project
                   exists to avoid. */
                Text(model.reviewQueueState.provenance(source: "review_queue"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.textSecondary)
            }

            /* Whether the schedule is alive, said out loud. Reading a queue
               tells you what is in it, never whether anything is still being
               put there — and a list that stopped being fed looks exactly
               like a quiet week. Refreshes itself every five minutes. */
            if let line = model.pipelineLine {
                Text(line)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(line.hasPrefix("⚠") ? .statusAmber : .textSecondary)
            }

            if !SupabaseAPI.isConfigured() {
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Connect Supabase to see scanned news").fontWeight(.semibold)
                        Text("Settings → Accounts → paste your project URL and anon (publishable) key. Then run the ingest Edge Function — interesting items appear here for review.")
                            .foregroundColor(.textSecondary).font(.callout)
                    }
                }
            } else if let err = model.reviewQueueError {
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Waiting list", systemImage: "exclamationmark.triangle")
                            .fontWeight(.semibold).foregroundColor(.statusRed)
                        Text(err).foregroundColor(.textSecondary).font(.callout)
                        Text("If this is a permissions error, run the SQL grant in supabase/SCAN_ONLY_SETUP.md (anon select on review_queue).")
                            .foregroundColor(.textSecondary).font(.caption)
                    }
                }
            } else if let clash = model.queueContradiction {
                /* The alarm nothing else in the stack can raise: the run says
                   it queued items, the queue returns none. Saying "empty" here
                   was the wrong advice on 9 August and cost an hour. */
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("The queue and the pipeline disagree", systemImage: "exclamationmark.2")
                            .fontWeight(.semibold).foregroundColor(.statusAmber)
                        Text(clash).foregroundColor(.textSecondary).font(.callout)
                        Text("Check the anon SELECT policy on ingested_items and the column grants — supabase/SCAN_ONLY_SETUP.md.")
                            .foregroundColor(.textSecondary).font(.caption)
                    }
                }
            } else if case .never = model.reviewQueueState {
                /* Not asked yet is not empty. The old code could not tell the
                   difference and asserted "empty" before the first fetch. */
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Not loaded yet").fontWeight(.semibold)
                        Text("The waiting list has not been fetched in this session.")
                            .foregroundColor(.textSecondary).font(.callout)
                        Button("Load now") { Task { await model.loadReviewQueue() } }
                            .buttonStyle(.borderless).font(.callout)
                    }
                }
            } else if model.reviewQueueState.isConfirmedEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Waiting list is empty").fontWeight(.semibold)
                        Text("Checked \(LoadState<Int>.ago(model.reviewQueueState.stamp ?? Date())) — nothing scored above the threshold. Trigger the ingest scan for a fresh sweep; nothing is written automatically.")
                            .foregroundColor(.textSecondary).font(.callout)
                    }
                }
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(model.reviewQueue.prefix(25)) { item in
                        ReviewQueueRow(item: item, seedDraft: { it in
                            model.newDraftFromQueue(clusterKey: DraftSeed.keyFor(it),
                                                    items: [it], author: "")
                        })
                    }
                    if model.reviewQueue.count > 25 {
                        Text("Showing 25 of \(model.reviewQueue.count) — open Supabase Table Editor for the rest.")
                            .font(.caption).foregroundColor(.textSecondary)
                    }
                }
            }
        }
    }

}
