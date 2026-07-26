import SwiftUI
import WebKit

/// Context for one Canva design-editing session inside the app.
struct CanvaSheetContext: Identifiable {
    let id: String            // design id
    let editURL: String
    let isCover: Bool         // cover → frontmatter; else insert at cursor
}

/// Canva design editor in a sheet (persistent data store + the existing
/// popup delegate for the login flow) with an "Import to article" toolbar.
/// Export runs async and cancellable; the editor is never blocked.
struct CanvaDesignSheet: View {
    let context: CanvaSheetContext
    /// Receives the exported PNG (data, suggestedName) — runs the EXISTING
    /// image pipeline in the editor (upload → frontmatter/cursor).
    var importAction: (Data, String) async -> Void
    @Environment(\.dismiss) private var dismiss

    @StateObject private var controller: CMSController
    @State private var exporting = false
    @State private var exportTask: Task<Void, Never>?
    @State private var errorText: String?

    init(context: CanvaSheetContext, importAction: @escaping (Data, String) async -> Void) {
        self.context = context
        self.importAction = importAction
        _controller = StateObject(wrappedValue: CMSController.shared(
            for: URL(string: context.editURL) ?? URL(string: "https://www.canva.com/")!))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(context.isCover ? "Cover design" : "Inline graphic")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.textPrimary)
                Text("· Canva").font(.caption).foregroundColor(.textSecondary)
                if let err = errorText {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundColor(.statusRed).lineLimit(1)
                }
                Spacer()
                if exporting {
                    ProgressView().controlSize(.small)
                    Text("Exporting from Canva…").font(.caption).foregroundColor(.textSecondary)
                    Button("Cancel") { exportTask?.cancel() }
                } else {
                    Button {
                        runImport()
                    } label: {
                        Label("Import to article", systemImage: "square.and.arrow.down.fill")
                    }
                    .keyboardShortcut(.defaultAction)
                }
                Button("Close") { exportTask?.cancel(); dismiss() }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            WebViewRepresentable(webView: controller.webView)
        }
        .frame(width: 1120, height: 760)
        .sheet(isPresented: Binding(
            get: { controller.popup != nil },
            set: { if !$0 { controller.popup = nil } }
        )) {
            VStack(spacing: 0) {
                HStack {
                    Text("Sign in").font(.headline)
                    Spacer()
                    Button("Close") { controller.popup = nil }
                }
                .padding(10)
                Divider()
                if let popup = controller.popup { WebViewRepresentable(webView: popup) }
            }
            .frame(width: 900, height: 680)
        }
    }

    private func runImport() {
        errorText = nil
        exporting = true
        exportTask = Task {
            defer { exporting = false }
            do {
                let jobID = try await CanvaAPI.startExport(designID: context.id)
                let url = try await CanvaAPI.waitForExport(jobID: jobID)
                let data = try await CanvaAPI.download(url)
                let name = context.isCover ? "cover.png" : "canva-graphic.png"
                await importAction(data, name)
                dismiss()
            } catch is CancellationError {
                errorText = "Export cancelled."
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}
