import SwiftUI
import WebKit

// MARK: - Plain wrapper

struct WebViewRepresentable: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

// MARK: - CMS (Sveltia) with OAuth-popup support

/// Owns the persistent CMS web view for one site. Cached per site so the
/// page (and login) survives tab switches; the default website data store
/// persists cookies across app restarts, so the GitHub OAuth session sticks.
final class CMSController: NSObject, ObservableObject, WKUIDelegate, WKNavigationDelegate {
    @Published var popup: WKWebView?
    @Published var pageTitle: String = ""
    let webView: WKWebView
    let homeURL: URL

    private static var cache: [String: CMSController] = [:]
    static func shared(for url: URL) -> CMSController {
        if let existing = cache[url.absoluteString] { return existing }
        let fresh = CMSController(url: url)
        cache[url.absoluteString] = fresh
        return fresh
    }

    private init(url: URL) {
        homeURL = url
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()                 // persistent session
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = true
        webView = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.load(URLRequest(url: url))
    }

    func reload() { webView.reload() }
    func goHome() { webView.load(URLRequest(url: homeURL)) }

    // Sveltia's GitHub login opens a popup window. WebKit hands us the
    // configuration the popup MUST be created with — same process pool and
    // data store — otherwise the OAuth window can't talk back to the opener.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        let child = WKWebView(frame: .zero, configuration: configuration)
        child.uiDelegate = self
        child.navigationDelegate = self
        popup = child
        return child
    }

    func webViewDidClose(_ webView: WKWebView) {
        if webView === popup { popup = nil }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === self.webView { pageTitle = webView.title ?? "" }
    }
}

struct CMSTabView: View {
    let site: SiteProject
    @StateObject private var controller: CMSController
    private let cmsURL: URL?

    init(site: SiteProject) {
        self.site = site
        let url = site.cms_url.flatMap(URL.init(string:))
        self.cmsURL = url
        // Fallback URL never loads (empty-state shown instead) but keeps the
        // StateObject non-optional.
        _controller = StateObject(wrappedValue: CMSController.shared(for: url ?? URL(string: "about:blank")!))
    }

    var body: some View {
        if cmsURL == nil {
            VStack(spacing: 8) {
                Image(systemName: "square.dashed").font(.largeTitle).foregroundColor(.secondary)
                Text("No CMS configured").font(.headline)
                Text("Add a \"cms_url\" to this project in projects.json (see scripts/build-projects.js).")
                    .font(.callout).foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Button { controller.reload() } label: { Image(systemName: "arrow.clockwise") }
                        .help("Reload")
                    Button { if let u = cmsURL { NSWorkspace.shared.open(u) } } label: {
                        Image(systemName: "safari")
                    }
                    .help("Open in Browser")
                    Text(controller.pageTitle.isEmpty ? (cmsURL?.absoluteString ?? "") : controller.pageTitle)
                        .font(.caption).foregroundColor(.secondary).lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                Divider()
                WebViewRepresentable(webView: controller.webView)
            }
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
                    if let popup = controller.popup {
                        WebViewRepresentable(webView: popup)
                    }
                }
                .frame(width: 900, height: 680)
            }
        }
    }
}

// MARK: - Design tab (Canva)

/// Canva in a persistent webview — same data-store + OAuth-popup pattern as
/// the Sveltia tab. The integration IS the workflow: design → download →
/// drag the export into the article editor (Change-2 pipeline picks it up).
struct DesignTabView: View {
    @StateObject private var controller = CMSController.shared(for: URL(string: "https://www.canva.com/")!)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { controller.webView.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!controller.webView.canGoBack).help("Back")
                Button { controller.webView.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!controller.webView.canGoForward).help("Forward")
                Button { controller.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Reload")
                Button { NSWorkspace.shared.open(URL(string: "https://www.canva.com/")!) } label: {
                    Image(systemName: "safari")
                }
                .help("Open in Browser")
                Divider().frame(height: 14)
                Link("New design (OG 1200×630)", destination: URL(string: "https://www.canva.com/create/")!)
                    .font(.caption)
                Spacer()
                Text(controller.pageTitle).font(.caption).foregroundColor(.textSecondary).lineLimit(1)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            Divider()
            WebViewRepresentable(webView: controller.webView)
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.doc").font(.caption).foregroundColor(.textSecondary)
                Text("Tip: use “Design cover in Canva” inside the article editor for automatic import — this full-screen tab is the manual fallback (download, then drag the file into your article).")
                    .font(.caption).foregroundColor(.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.bgCard)
        }
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
                if let popup = controller.popup {
                    WebViewRepresentable(webView: popup)
                }
            }
            .frame(width: 900, height: 680)
        }
    }
}

// MARK: - Markdown preview

/// Renders markdown in a WKWebView using marked.js (CDN) inside a local HTML
/// shell that pulls the site's own stylesheet — base URL is the live site, so
/// relative /assets/… paths resolve. Re-renders are debounced 400 ms.
final class PreviewController: NSObject, ObservableObject, WKNavigationDelegate {
    let webView: WKWebView
    private var ready = false
    private var queuedMarkdown: String?
    private var pending: DispatchWorkItem?

    override init() {
        let cfg = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        webView.navigationDelegate = self
        webView.loadHTMLString(Self.shell, baseURL: URL(string: "https://lexdigestglobal.com/"))
    }

    func update(markdown: String) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.render(markdown) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func renderNow(_ markdown: String) {
        pending?.cancel()
        render(markdown)
    }

    private func render(_ markdown: String) {
        guard ready else { queuedMarkdown = markdown; return }
        guard let data = try? JSONSerialization.data(withJSONObject: markdown, options: .fragmentsAllowed),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.renderMarkdown(\(json));", completionHandler: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        if let queued = queuedMarkdown {
            queuedMarkdown = nil
            render(queued)
        }
    }

    private static let shell = """
    <!doctype html><html><head><meta charset="utf-8">
    <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Playfair+Display:ital,wght@0,700;0,900;1,700&family=EB+Garamond:ital,wght@0,400;0,700;1,400;1,700&family=Inter:wght@400;600&display=swap">
    <link rel="stylesheet" href="/assets/css/style.css">
    <style>
      body { background: #fff; margin: 0; padding: 26px 30px; }
      .cockpit-preview { max-width: 700px; margin: 0 auto;
        font-family: 'EB Garamond', Georgia, serif; font-size: 1.05rem;
        line-height: 1.75; color: #111; }
      .cockpit-preview h1, .cockpit-preview h2, .cockpit-preview h3 {
        font-family: 'Playfair Display', Georgia, serif; color: #1F2A44; line-height: 1.15; }
      .cockpit-preview img { max-width: 100%; height: auto; }
      .cockpit-preview blockquote { border-left: 3px solid #C9B58C; margin-left: 0;
        padding-left: 1rem; color: #444; }
      .cockpit-preview code { font-family: ui-monospace, Menlo, monospace; font-size: 0.9em;
        background: #f4f2ec; padding: 1px 4px; border-radius: 3px; }
      .cockpit-preview .pull-quote { border-left: 3px solid #C9B58C;
        padding: 0.75rem 0 0.75rem 1.25rem; margin: 2rem 0; font-family: 'Playfair Display', serif;
        font-style: italic; font-size: 1.25rem; }
      .cockpit-preview .callout { border: 1px solid #d5e3f5; background: #eef4fc;
        border-radius: 8px; padding: 0.7rem 1.1rem; margin: 1.5rem 0; font-size: 0.95em; }
      .cockpit-preview .callout--warn { border-color: #f0dcb8; background: #fdf6e7; }
      .cockpit-preview .keyfacts { border: 1px solid #E5E7EB; background: #FAFAF8;
        border-radius: 8px; padding: 0.8rem 1.1rem; margin: 1.5rem 0; }
      .cockpit-preview figure { margin: 1.75rem 0; }
      .cockpit-preview figcaption { font-family: 'Inter', sans-serif; font-size: 0.8rem;
        color: #6B7280; margin-top: 6px; }
    </style>
    <script src="https://cdn.jsdelivr.net/npm/marked@12.0.2/marked.min.js"></script>
    </head><body>
    <article class="cockpit-preview" id="out"><p style="color:#999;font-family:Inter,sans-serif;font-size:13px;">Preview loads as you type…</p></article>
    <script>
      window.renderMarkdown = function (md) {
        if (window.marked) { document.getElementById('out').innerHTML = marked.parse(md); }
      };
    </script>
    </body></html>
    """
}
