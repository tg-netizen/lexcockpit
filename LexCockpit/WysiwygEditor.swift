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
    /// Right-click on an image inside the editor (src passed through).
    var onImageMenu: ((String) -> Void)?
    var onBlockEdit: ((Int) -> Void)?
    var onBlockDelete: ((Int) -> Void)?
    var onBlockInsert: ((String, String?) -> Void)?
    var onImagePick: (() -> Void)?

    private var pendingLoad: String?
    private var pendingMode: (mode: String, lock: Bool)?

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

    /// Detects site design blocks whose raw HTML Toast's WYSIWYG mode
    /// does NOT round-trip (it strips the container divs). Such articles
    /// must be edited in markdown mode, which is byte-faithful.
    static func hasDesignBlocks(_ md: String) -> Bool {
        md.range(of: #"<div class="(pull-quote|callout|keyfacts)"#,
                 options: .regularExpression) != nil
            || md.contains("<figure")
    }

    /// Must take effect BEFORE the markdown is loaded: setMarkdown while the
    /// WYSIWYG mode is active already normalizes HTML blocks away.
    func setMode(_ mode: String, lock: Bool = false) {
        guard ready else { pendingMode = (mode, lock); return }
        var js = "window.__editor && window.__editor.changeMode('\(mode)', true);"
        if lock {
            js += " var __ms = document.querySelector('.toastui-editor-mode-switch'); if (__ms) __ms.style.display = 'none';"
        }
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// Scroll the canvas to a vaulted block after a reload.
    func revealVault(_ index: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.webView.evaluateJavaScript("window.__revealVault && window.__revealVault(\(index));",
                                             completionHandler: nil)
        }
    }

    /// Drop the plain-text insertion marker at the caret (Swift-initiated
    /// inserts: toolbar menu, figure flow).
    func placeInsertionMarker() {
        webView.evaluateJavaScript(
            "window.__editor && window.__editor.focus(); window.__placeMarker && window.__placeMarker();",
            completionHandler: nil)
    }

    func setTypewriter(_ on: Bool) {
        webView.evaluateJavaScript("window.__setTypewriter && window.__setTypewriter(\(on));",
                                   completionHandler: nil)
    }

    /// Push the block palette into the shell for the slash menu.
    func installBlocks(json: String) {
        webView.evaluateJavaScript("window.__blocks = \(json); undefined;", completionHandler: nil)
    }

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
            if let pm = pendingMode { pendingMode = nil; setMode(pm.mode, lock: pm.lock) }
            if let pending = pendingLoad { pendingLoad = nil; call("loadMarkdown", pending) }
        case "change":
            if let md = body["md"] as? String { onChange?(md) }
        case "imgmenu":
            if let src = body["src"] as? String { onImageMenu?(src) }
        case "blockedit":
            if let i = body["vault"] as? Int { onBlockEdit?(i) }
        case "blockdelete":
            if let i = body["vault"] as? Int { onBlockDelete?(i) }
        case "blockinsert":
            onBlockInsert?((body["kind"] as? String) ?? "", body["text"] as? String)
        case "imagepick":
            onImagePick?()
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
      .toastui-editor-contents .pull-quote { border-left: 3px solid #C9B58C;
        padding: 0.75rem 0 0.75rem 1.25rem; margin: 1.5rem 0; font-style: italic; font-size: 1.2em; }
      .toastui-editor-contents .callout { border: 1px solid #d5e3f5; background: #eef4fc;
        border-radius: 8px; padding: 0.6rem 1rem; margin: 1.2rem 0; }
      .toastui-editor-contents .callout--warn { border-color: #f0dcb8; background: #fdf6e7; }
      .toastui-editor-contents .keyfacts { border: 1px solid #E5E7EB; background: #FAFAF8;
        border-radius: 8px; padding: 0.7rem 1rem; margin: 1.2rem 0; }
      .toastui-editor-contents figcaption { font-size: 0.85em; color: #6B7280;
        font-family: 'Inter', sans-serif; margin-top: 4px; }
      .toastui-editor-mode-switch { display: none !important; }
      .toastui-editor-ww-container [data-vault]:hover { outline: 2px solid #C5D4E8;
        outline-offset: 3px; border-radius: 3px; cursor: default; }
      #bubble { position: fixed; z-index: 1000; display: none; background: #1F2A37;
        border-radius: 9px; padding: 3px 4px; box-shadow: 0 8px 24px rgba(0,0,0,0.28);
        font-family: 'Inter', sans-serif; white-space: nowrap; }
      #bubble button { background: none; border: none; color: #fff; font-size: 12.5px;
        padding: 6px 9px; border-radius: 6px; cursor: pointer; font-family: inherit; }
      #bubble button:hover { background: rgba(255,255,255,0.16); }
      #bubble .sep { display: inline-block; width: 1px; height: 16px;
        background: rgba(255,255,255,0.25); margin: 0 3px; vertical-align: middle; }
      #bubble input { background: #111827; border: 1px solid #374151; color: #fff;
        font-size: 12px; padding: 5px 8px; border-radius: 6px; margin: 3px;
        width: 250px; font-family: inherit; display: none; }
      #plusbtn { position: fixed; z-index: 999; display: none; width: 24px; height: 24px;
        border-radius: 12px; border: 1px solid #D6DDE7; background: #fff; color: #1F3A5F;
        font-size: 16px; line-height: 21px; text-align: center; cursor: pointer;
        box-shadow: 0 2px 8px rgba(0,0,0,0.10); user-select: none; }
      #plusbtn:hover { background: #F2F6FB; }
      #gallery { position: fixed; z-index: 1001; display: none; width: 560px;
        max-height: 430px; overflow: auto; background: #fff; border: 1px solid #E5E7EB;
        border-radius: 14px; box-shadow: 0 16px 48px rgba(0,0,0,0.18); padding: 12px;
        font-family: 'Inter', sans-serif; }
      #gallery h4 { margin: 2px 4px 10px; font-size: 11px; text-transform: uppercase;
        letter-spacing: 0.06em; color: #6B7280; font-weight: 600; }
      #gallery .cards { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; }
      .bcard { border: 1px solid #E5E7EB; border-radius: 10px; padding: 10px; cursor: pointer; }
      .bcard.sel, .bcard:hover { border-color: #1F3A5F; background: #F4F7FB; }
      .bprev { height: 56px; overflow: hidden; pointer-events: none; margin-bottom: 8px; }
      .bprev .inner { transform: scale(0.55); transform-origin: top left; width: 182%;
        font-family: 'EB Garamond', Georgia, serif; font-size: 15px; }
      .bprev .inner .pull-quote { border-left: 3px solid #C9B58C; padding: 4px 0 4px 12px;
        font-style: italic; margin: 0; }
      .bprev .inner .callout { border: 1px solid #d5e3f5; background: #eef4fc;
        border-radius: 8px; padding: 6px 10px; margin: 0; }
      .bprev .inner .callout--warn { border-color: #f0dcb8; background: #fdf6e7; }
      .bprev .inner .keyfacts { border: 1px solid #E5E7EB; background: #FAFAF8;
        border-radius: 8px; padding: 6px 10px; margin: 0; }
      .bprev .inner figcaption { font-size: 0.8em; color: #6B7280; font-family: 'Inter', sans-serif; }
      .bname { font-size: 12.5px; font-weight: 600; color: #111; }
      .bdesc { font-size: 11px; color: #6B7280; margin-top: 2px; }
      #blockbar { position: fixed; z-index: 1000; display: none; background: #1F2A37;
        border-radius: 8px; padding: 3px 4px; box-shadow: 0 8px 24px rgba(0,0,0,0.28);
        font-family: 'Inter', sans-serif; }
      #blockbar button { background: none; border: none; color: #fff; font-size: 12px;
        padding: 5px 10px; border-radius: 5px; cursor: pointer; font-family: inherit; }
      #blockbar button:hover { background: rgba(255,255,255,0.16); }
      #blockbar button.del:hover { background: #7F1D1D; }
      body.typewriter .toastui-editor-contents { padding-bottom: 55vh; padding-top: 20vh; }
      body.typewriter .toastui-editor-contents > * { opacity: 0.35; transition: opacity 0.25s ease; }
      body.typewriter .toastui-editor-contents > .tw-active { opacity: 1; }
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
        customHTMLRenderer: {
          htmlBlock: {
            div: function (node) {
              return [
                { type: 'openTag', tagName: 'div', outerNewLine: true, attributes: node.attrs },
                { type: 'html', content: node.childrenHTML },
                { type: 'closeTag', tagName: 'div', outerNewLine: true }
              ];
            },
            figure: function (node) {
              return [
                { type: 'openTag', tagName: 'figure', outerNewLine: true, attributes: node.attrs },
                { type: 'html', content: node.childrenHTML },
                { type: 'closeTag', tagName: 'figure', outerNewLine: true }
              ];
            }
          }
        },
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
        try { editor.replaceSelection(md); } catch (e) { editor.insertText(md); }
      };
      window.__imageUploaded = function (id, path) {
        var cb = imageCallbacks[id];
        if (cb) { cb(path, ''); delete imageCallbacks[id]; }
      };

      // ── Design-block cards: rendered, atomic, click-to-edit ────
      var NL = String.fromCharCode(10);
      var mo = new MutationObserver(function () {
        var els = document.querySelectorAll('.toastui-editor-ww-container [data-vault]:not([contenteditable])');
        for (var i = 0; i < els.length; i++) els[i].setAttribute('contenteditable', 'false');
      });
      mo.observe(document.body, { childList: true, subtree: true });

      var blockbar = document.createElement('div');
      blockbar.id = 'blockbar';
      var bbEdit = document.createElement('button');
      bbEdit.textContent = 'Edit';
      var bbDel = document.createElement('button');
      bbDel.textContent = 'Delete';
      bbDel.className = 'del';
      blockbar.appendChild(bbEdit); blockbar.appendChild(bbDel);
      document.body.appendChild(blockbar);
      var barTarget = null;
      function hideBlockbar() { blockbar.style.display = 'none'; barTarget = null; }
      bbEdit.onclick = function () {
        if (barTarget) bridge.postMessage({ type: 'blockedit', vault: parseInt(barTarget.getAttribute('data-vault'), 10) });
        hideBlockbar();
      };
      bbDel.onclick = function () {
        if (barTarget) bridge.postMessage({ type: 'blockdelete', vault: parseInt(barTarget.getAttribute('data-vault'), 10) });
        hideBlockbar();
      };
      document.addEventListener('click', function (ev) {
        var el = ev.target && ev.target.closest ? ev.target.closest('[data-vault]') : null;
        if (el && el.closest('.toastui-editor-ww-container')) {
          barTarget = el;
          var r = el.getBoundingClientRect();
          blockbar.style.display = 'block';
          blockbar.style.left = Math.max(8, r.left) + 'px';
          blockbar.style.top = Math.max(8, r.top - 38) + 'px';
        } else if (!blockbar.contains(ev.target)) hideBlockbar();
      });
      window.__revealVault = function (i) {
        var el = document.querySelector('[data-vault~=' + JSON.stringify(String(i)) + ']') ||
                 document.querySelector('[data-vault]');
        var els = document.querySelectorAll('[data-vault]');
        for (var k = 0; k < els.length; k++) {
          if (els[k].getAttribute('data-vault') === String(i)) { el = els[k]; break; }
        }
        if (el) el.scrollIntoView({ block: 'center', behavior: 'smooth' });
      };

      // ── Floating format bubble (Canva/Medium style) ────────────
      var bubble = document.createElement('div');
      bubble.id = 'bubble';
      function bbtn(label, title, fn) {
        var b = document.createElement('button');
        b.textContent = label; b.title = title;
        b.onmousedown = function (ev) { ev.preventDefault(); };
        b.onclick = function (ev) { ev.preventDefault(); fn(); };
        bubble.appendChild(b);
        return b;
      }
      function sep() { var d = document.createElement('span'); d.className = 'sep'; bubble.appendChild(d); }
      function hideBubble() { bubble.style.display = 'none'; linkInput.style.display = 'none'; }
      bbtn('B', 'Bold', function () { editor.exec('bold'); });
      bbtn('I', 'Italic', function () { editor.exec('italic'); });
      sep();
      bbtn('H2', 'Heading 2', function () { editor.exec('heading', { level: 2 }); hideBubble(); });
      bbtn('H3', 'Heading 3', function () { editor.exec('heading', { level: 3 }); hideBubble(); });
      sep();
      bbtn('Quote', 'Blockquote', function () { editor.exec('blockQuote'); hideBubble(); });
      bbtn('Pull-quote', 'Lift this sentence into a styled pull quote', function () {
        var t = '';
        try { t = editor.getSelectedText() || ''; } catch (e) {}
        if (!t) { hideBubble(); return; }
        placeMarker();
        hideBubble();
        bridge.postMessage({ type: 'blockinsert', kind: 'pullquote', text: t });
      });
      sep();
      bbtn('Link', 'Add link', function () {
        linkInput.style.display = linkInput.style.display === 'inline-block' ? 'none' : 'inline-block';
        if (linkInput.style.display === 'inline-block') linkInput.focus();
      });
      var linkInput = document.createElement('input');
      linkInput.placeholder = 'https://…  (Enter)';
      linkInput.onmousedown = function (ev) { ev.stopPropagation(); };
      linkInput.onkeydown = function (ev) {
        if (ev.key === 'Enter') {
          ev.preventDefault();
          var url = linkInput.value.trim();
          if (url) {
            var txt = '';
            try { txt = editor.getSelectedText() || url; } catch (e) { txt = url; }
            editor.exec('addLink', { linkUrl: url, linkText: txt });
          }
          linkInput.value = '';
          hideBubble();
        }
        if (ev.key === 'Escape') hideBubble();
      };
      bubble.appendChild(linkInput);
      document.body.appendChild(bubble);

      var bubbleTimer = null;
      function updateBubble() {
        var sel = window.getSelection();
        if (!sel || sel.isCollapsed || !sel.rangeCount) { hideBubble(); return; }
        var range = sel.getRangeAt(0);
        var el = range.commonAncestorContainer;
        el = el.nodeType === 1 ? el : el.parentElement;
        if (!el || !el.closest('.toastui-editor-ww-container') || el.closest('[data-vault]')) { hideBubble(); return; }
        var rect = range.getBoundingClientRect();
        if (!rect || (!rect.width && !rect.height)) { hideBubble(); return; }
        bubble.style.display = 'block';
        var left = rect.left + rect.width / 2 - bubble.offsetWidth / 2;
        left = Math.max(8, Math.min(left, window.innerWidth - bubble.offsetWidth - 8));
        var top = rect.top - bubble.offsetHeight - 8;
        if (top < 8) top = rect.bottom + 8;
        bubble.style.left = left + 'px';
        bubble.style.top = top + 'px';
      }
      document.addEventListener('selectionchange', function () {
        if (bubbleTimer) clearTimeout(bubbleTimer);
        bubbleTimer = setTimeout(updateBubble, 140);
      });

      // ── "+" handle + visual block gallery ──────────────────────
      window.__blocks = window.__blocks || [];
      var plus = document.createElement('div');
      plus.id = 'plusbtn';
      plus.textContent = '+';
      plus.title = 'Insert a block here';
      document.body.appendChild(plus);
      var plusTarget = null;

      function wwRoot() { return document.querySelector('.toastui-editor-ww-container .ProseMirror'); }
      document.addEventListener('mousemove', function (ev) {
        var root = wwRoot();
        if (!root) return;
        if (ev.target === plus) return;
        var t = ev.target;
        if (!root.contains(t)) {
          if (!plus.contains(ev.target)) plus.style.display = 'none';
          return;
        }
        while (t && t.parentElement !== root) t = t.parentElement;
        if (!t || t.hasAttribute('data-vault')) { plus.style.display = 'none'; return; }
        plusTarget = t;
        var r = t.getBoundingClientRect();
        var rr = root.getBoundingClientRect();
        plus.style.display = 'block';
        plus.style.left = (rr.left - 32) + 'px';
        plus.style.top = (r.top + 1) + 'px';
      });

      var gallery = document.createElement('div');
      gallery.id = 'gallery';
      document.body.appendChild(gallery);
      var gIdx = 0, gOpen = false, slashTriggered = false;
      function closeGallery() { gallery.style.display = 'none'; gOpen = false; }
      function renderGallery() {
        gallery.innerHTML = '';
        var h = document.createElement('h4');
        h.textContent = 'Insert block';
        gallery.appendChild(h);
        var grid = document.createElement('div');
        grid.className = 'cards';
        window.__blocks.forEach(function (b, i) {
          var card = document.createElement('div');
          card.className = 'bcard' + (i === gIdx ? ' sel' : '');
          var prev = document.createElement('div');
          prev.className = 'bprev';
          var inner = document.createElement('div');
          inner.className = 'inner';
          inner.innerHTML = b.preview || '';
          prev.appendChild(inner);
          var name = document.createElement('div');
          name.className = 'bname';
          name.textContent = b.label;
          var desc = document.createElement('div');
          desc.className = 'bdesc';
          desc.textContent = b.desc || '';
          card.appendChild(prev); card.appendChild(name); card.appendChild(desc);
          card.onmousedown = function (ev) { ev.preventDefault(); chooseCard(i); };
          grid.appendChild(card);
        });
        gallery.appendChild(grid);
      }
      function openGallery(anchorRect) {
        gIdx = 0;
        renderGallery();
        gallery.style.display = 'block';
        var left = Math.min(anchorRect.left, window.innerWidth - 580);
        var top = anchorRect.bottom + 8;
        if (top + Math.min(gallery.offsetHeight, 430) > window.innerHeight - 8) {
          top = Math.max(8, anchorRect.top - gallery.offsetHeight - 8);
        }
        gallery.style.left = Math.max(8, left) + 'px';
        gallery.style.top = top + 'px';
        gOpen = true;
      }
      function placeMarker() {
        try { editor.replaceSelection(NL + NL + '@@BLOCKINS@@' + NL + NL); }
        catch (e) { editor.insertText(NL + NL + '@@BLOCKINS@@' + NL + NL); }
      }
      window.__placeMarker = placeMarker;
      function chooseCard(i) {
        var b = window.__blocks[i];
        var wasSlash = slashTriggered;
        slashTriggered = false;
        closeGallery();
        if (!b) return;
        if (wasSlash) { try { document.execCommand('delete'); } catch (e) {} }
        placeMarker();
        if (b.action === 'imagepick') { bridge.postMessage({ type: 'imagepick' }); return; }
        bridge.postMessage({ type: 'blockinsert', kind: b.id });
      }
      plus.onmousedown = function (ev) { ev.preventDefault(); };
      plus.onclick = function () {
        if (!plusTarget) return;
        var range = document.createRange();
        range.selectNodeContents(plusTarget);
        range.collapse(false);
        var sel = window.getSelection();
        sel.removeAllRanges();
        sel.addRange(range);
        slashTriggered = false;
        openGallery(plusTarget.getBoundingClientRect());
      };
      document.addEventListener('keydown', function (ev) {
        if (!gOpen) {
          if (ev.key === '/') {
            var sel = window.getSelection();
            if (!sel || !sel.anchorNode) return;
            var el = sel.anchorNode.nodeType === 1 ? sel.anchorNode : sel.anchorNode.parentElement;
            if (!el || !el.closest('.toastui-editor-ww-container')) return;
            var text = (sel.anchorNode.textContent || '').trim();
            if (text !== '') return;
            slashTriggered = true;
            setTimeout(function () {
              var r = window.getSelection().getRangeAt(0).getBoundingClientRect();
              openGallery(r);
            }, 0);
          }
          return;
        }
        var n = window.__blocks.length;
        if (ev.key === 'ArrowRight' || ev.key === 'ArrowDown') { ev.preventDefault(); gIdx = (gIdx + (ev.key === 'ArrowDown' ? 2 : 1)) % n; renderGallery(); return; }
        if (ev.key === 'ArrowLeft' || ev.key === 'ArrowUp') { ev.preventDefault(); gIdx = (gIdx + n - (ev.key === 'ArrowUp' ? 2 : 1)) % n; renderGallery(); return; }
        if (ev.key === 'Enter') { ev.preventDefault(); ev.stopPropagation(); chooseCard(gIdx); return; }
        if (ev.key === 'Escape') { slashTriggered = false; closeGallery(); return; }
        if (ev.key.length === 1 || ev.key === 'Backspace') { slashTriggered = false; closeGallery(); }
      }, true);
      document.addEventListener('mousedown', function (ev) {
        if (gOpen && !gallery.contains(ev.target) && ev.target !== plus) { slashTriggered = false; closeGallery(); }
      });
      document.addEventListener('scroll', function () {
        hideBlockbar(); hideBubble(); plus.style.display = 'none';
        if (gOpen) { slashTriggered = false; closeGallery(); }
      }, true);

      // ── Typewriter mode (focus): centered caret + paragraph spotlight ──
      var twOn = false;
      var twTimer = null;
      window.__setTypewriter = function (on) {
        twOn = !!on;
        document.body.classList.toggle('typewriter', twOn);
        if (!twOn) {
          var act = document.querySelector('.tw-active');
          if (act) act.classList.remove('tw-active');
        } else { twTick(); }
      };
      function twTick() {
        if (!twOn) return;
        var sel = window.getSelection();
        if (!sel || !sel.anchorNode) return;
        var node = sel.anchorNode.nodeType === 1 ? sel.anchorNode : sel.anchorNode.parentElement;
        var root = document.querySelector('.toastui-editor-contents');
        if (!node || !root) return;
        while (node && node.parentElement !== root) node = node.parentElement;
        if (node) {
          var prev = document.querySelector('.tw-active');
          if (prev && prev !== node) prev.classList.remove('tw-active');
          node.classList.add('tw-active');
        }
        try {
          var rect = sel.getRangeAt(0).getBoundingClientRect();
          if (rect && rect.top) {
            var target = window.innerHeight * 0.45;
            var scroller = document.querySelector('.toastui-editor-ww-container .toastui-editor') || document.scrollingElement;
            var delta = rect.top - target;
            if (Math.abs(delta) > 14) scroller.scrollBy({ top: delta, behavior: 'smooth' });
          }
        } catch (e) {}
      }
      document.addEventListener('selectionchange', function () {
        if (!twOn) return;
        if (twTimer) clearTimeout(twTimer);
        twTimer = setTimeout(twTick, 90);
      });

      // ── Image context menu → Swift ─────────────────────────────
      document.addEventListener('contextmenu', function (ev) {
        var t = ev.target;
        if (t && t.tagName === 'IMG') {
          ev.preventDefault();
          bridge.postMessage({ type: 'imgmenu', src: t.getAttribute('src') || '' });
        }
      });

      bridge.postMessage({ type: 'ready' });
    </script>
    </body></html>
    """
}
