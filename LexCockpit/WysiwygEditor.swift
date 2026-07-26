import SwiftUI
import WebKit

/// Toast UI trims leading/trailing blank lines around a document. To keep
/// unedited files byte-identical, we peel that whitespace envelope off before
/// loading and re-wrap the editor's output with it on every change.
enum MarkdownEnvelope {
    static func split(_ s: String) -> (prefix: String, core: String, suffix: String) {
        if s.trimmingCharacters(in: .newlines).isEmpty { return (s, "", "") }
        var core = s
        var prefix = ""
        while core.hasPrefix("\n") { prefix += "\n"; core.removeFirst() }
        var suffix = ""
        while core.hasSuffix("\n") { suffix += "\n"; core.removeLast() }
        return (prefix, core, suffix)
    }

    static func rewrap(_ editorOutput: String, prefix: String, suffix: String) -> String {
        var core = editorOutput
        while core.hasPrefix("\n") { core.removeFirst() }
        while core.hasSuffix("\n") { core.removeLast() }
        return prefix + core + suffix
    }
}

/// Toast UI Editor (MIT, CDN) in a WKWebView — the WYSIWYG writing surface.
///
/// Bridge contract (WKScriptMessageHandler "bridge"):
///   JS → Swift:  {type:"ready"}                      editor booted
///                {type:"change", md:String}          debounced 500 ms
///                {type:"image", id, name, dataB64}   pasted/dropped into editor
///   Swift → JS:  loadMarkdown(md)                    programmatic (no change event)
///                insertMarkdown(md)                  at cursor
///                __imageUploaded(id, path)           resolve pending image hook
///
/// The document's save / dirty / SHA-conflict logic is untouched: the bridge
/// only writes into the same `bodyText` the raw editor used.
final class WysiwygController: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {
    let webView: WKWebView
    @Published var ready = false

    /// Called with the current markdown after every (debounced) user edit.
    var onChange: ((String) -> Void)?
    /// Called when an image lands in the editor (paste or drop inside webview).
    var onImage: ((_ id: String, _ name: String, _ data: Data) -> Void)?

    private var pendingLoad: String?

    override init() {
        let cfg = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        webView = WKWebView(frame: .zero, configuration: {
            cfg.userContentController = ucc
            return cfg
        }())
        super.init()
        ucc.add(self, name: "bridge")
        webView.navigationDelegate = self
        webView.loadHTMLString(Self.shell, baseURL: URL(string: "https://lexdigestglobal.com/"))
    }

    // MARK: Swift → JS

    func load(markdown: String) {
        guard ready else { pendingLoad = markdown; return }
        call("loadMarkdown", markdown)
    }

    func insert(markdown: String) { call("insertMarkdown", markdown) }

    func imageUploaded(id: String, path: String) {
        guard let idJSON = Self.json(id), let pathJSON = Self.json(path) else { return }
        webView.evaluateJavaScript("window.__imageUploaded(\(idJSON), \(pathJSON));", completionHandler: nil)
    }

    /// Fetch the editor's current markdown directly (used by the round-trip test).
    func currentMarkdown(_ completion: @escaping (String?) -> Void) {
        webView.evaluateJavaScript("window.__editor ? window.__editor.getMarkdown() : null") { value, _ in
            completion(value as? String)
        }
    }

    private func call(_ fn: String, _ arg: String) {
        guard let json = Self.json(arg) else { return }
        webView.evaluateJavaScript("window.\(fn)(\(json));", completionHandler: nil)
    }

    private static func json(_ s: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: s, options: .fragmentsAllowed) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: JS → Swift

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "bridge", let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            ready = true
            if let pending = pendingLoad { pendingLoad = nil; call("loadMarkdown", pending) }
        case "change":
            if let md = body["md"] as? String { onChange?(md) }
        case "image":
            if let id = body["id"] as? String,
               let name = body["name"] as? String,
               let b64 = body["dataB64"] as? String,
               let data = Data(base64Encoded: b64) {
                onImage?(id, name, data)
            }
        default: break
        }
    }

    // MARK: Shell

    /// Site typography inside the WYSIWYG surface (serif headings / sans body)
    /// so writing feels like the published page. usageStatistics off — no
    /// telemetry. Toolbar limited to what the site renders.
    private static let shell = """
    <!doctype html><html><head><meta charset="utf-8">
    <link rel="stylesheet" href="https://uicdn.toast.com/editor/latest/toastui-editor.min.css">
    <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Playfair+Display:wght@700;900&family=EB+Garamond:ital,wght@0,400;0,700;1,400&family=Inter:wght@400;600&display=swap">
    <style>
      html, body { margin: 0; height: 100%; background: #fff; }
      #editor { height: 100vh; }
      .toastui-editor-defaultUI { border: none; }
      .toastui-editor-contents { font-family: 'EB Garamond', Georgia, serif;
        font-size: 17px; line-height: 1.75; color: #111; max-width: 760px; margin: 0 auto; }
      .toastui-editor-contents h1, .toastui-editor-contents h2, .toastui-editor-contents h3 {
        font-family: 'Playfair Display', Georgia, serif; color: #1F2A44; border: none; }
      .toastui-editor-contents blockquote { border-left: 3px solid #C9B58C; color: #444; }
      .toastui-editor-contents code { background: #f4f2ec; }
      .toastui-editor-contents img { max-width: 100%; }
      .toastui-editor-md-container .toastui-editor md-preview { display: none; }
    </style>
    <script src="https://uicdn.toast.com/editor/latest/toastui-editor-all.min.js"></script>
    </head><body>
    <div id="editor"></div>
    <script>
      var bridge = window.webkit.messageHandlers.bridge;
      var suppress = false;
      var timer = null;
      var imageCallbacks = {};
      var imageSeq = 0;

      var editor = new toastui.Editor({
        el: document.getElementById('editor'),
        height: '100%',
        initialEditType: 'wysiwyg',
        previewStyle: 'tab',
        usageStatistics: false,
        autofocus: false,
        toolbarItems: [
          ['heading', 'bold', 'italic'],
          ['quote', 'ul', 'ol'],
          ['table', 'link', 'image'],
          ['code', 'codeblock', 'hr']
        ],
        hooks: {
          addImageBlobHook: function (blob, callback) {
            var id = 'img' + (++imageSeq);
            imageCallbacks[id] = callback;
            var reader = new FileReader();
            reader.onload = function () {
              var b64 = String(reader.result).split(',')[1] || '';
              bridge.postMessage({ type: 'image', id: id,
                name: (blob && blob.name) || 'pasted.png', dataB64: b64 });
            };
            reader.readAsDataURL(blob);
            return false;
          }
        },
        events: {
          change: function () {
            if (suppress) return;
            if (timer) clearTimeout(timer);
            timer = setTimeout(function () {
              bridge.postMessage({ type: 'change', md: editor.getMarkdown() });
            }, 500);
          }
        }
      });
      window.__editor = editor;

      window.loadMarkdown = function (md) {
        suppress = true;
        editor.setMarkdown(md, false);
        setTimeout(function () { suppress = false; }, 80);
      };
      window.insertMarkdown = function (md) {
        editor.insertText(md);
      };
      window.__imageUploaded = function (id, path) {
        var cb = imageCallbacks[id];
        if (cb) { cb(path, ''); delete imageCallbacks[id]; }
      };

      bridge.postMessage({ type: 'ready' });
    </script>
    </body></html>
    """
}
