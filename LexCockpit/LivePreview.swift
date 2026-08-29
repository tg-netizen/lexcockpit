import SwiftUI
import WebKit

/*  LivePreview.swift — die Vorschau ist der Editor
 *  ═══════════════════════════════════════════════════════════════════
 *  Bis hierher war die Arbeit: links eine Liste von Bloecken mit Pfeilen,
 *  rechts eine Vorschau. Man aendert an einer Stelle und schaut an einer
 *  anderen nach. Das ist die Bedienung eines Werkzeugs fuer Leute, die
 *  wissen, wie die Seite gebaut ist, und nicht die Bedienung fuer jemanden,
 *  der eine Seite machen will.
 *
 *  Also faellt die Trennung weg. Hier steht die Seite, so wie sie
 *  aussieht, und man arbeitet in ihr: Text anklicken und tippen, einen
 *  Block am Griff nehmen und woandershin ziehen.
 *
 *  ── Was "wie Canva" hier heissen kann und was nicht ───────────────────
 *  Nicht: ein Block liegt auf x 300, y 520. Eine Website ist kein Blatt
 *  Papier, sie ist ein Dokument, das sich an jede Fensterbreite und jedes
 *  Telefon anpassen muss. Ein frei gesetzter Absatz waere auf dem einen
 *  Geraet richtig und auf allen anderen falsch, und das faellt erst dem
 *  Leser auf.
 *
 *  Sondern: unmittelbares Anfassen INNERHALB des Dokumentflusses. Der
 *  Block geht vor den naechsten oder hinter ihn, in diesen Abschnitt oder
 *  in jenen. Das ist die ganze Freiheit, die eine Website hat, und in ihr
 *  soll nichts mehr im Weg stehen.
 *
 *  ── Warum beim Tippen nicht neu gezeichnet wird ───────────────────────
 *  Wuerde das Modell bei jedem Tastendruck neu rendern, spraenge der
 *  Cursor an den Anfang. Der Neuaufbau haengt deshalb an einem Schluessel,
 *  der nur die STRUKTUR beschreibt, Reihenfolge und Typen. Text aendert
 *  ihn nicht.
 */

struct LivePreview: NSViewRepresentable {
    @ObservedObject var model: WorkspaceModel
    let page: SitePage
    let site: SiteProject
    let dark: Bool
    /// Welcher Block gerade ausgewaehlt ist, fuer die Leiste daneben.
    @Binding var selection: String?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        ucc.add(context.coordinator, name: "edit")
        cfg.userContentController = ucc
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.setValue(false, forKey: "drawsBackground")
        context.coordinator.web = web
        context.coordinator.reload(force: true)
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.reload(force: false)
    }

    // MARK: - Die Bruecke

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var parent: LivePreview
        weak var web: WKWebView?
        /// Zuletzt gezeichnete Struktur. Nur wenn die sich aendert, wird
        /// neu geladen; sonst waere Tippen unmoeglich.
        private var lastStructure = ""
        private var lastTheme: Bool?

        init(_ parent: LivePreview) { self.parent = parent }

        /// Reihenfolge und Typen, ohne Text. Genau das, was ein Neuaufbau
        /// sichtbar machen muss.
        private var structure: String {
            /* Bewusst in Schritten. Als ein Ausdruck geschrieben brauchte
               der Typpruefer zu lange und brach ab. */
            var parts: [String] = []
            for (si, sec) in parent.page.sections.enumerated() {
                let types: String = sec.blocks.map { $0.type }.joined(separator: ",")
                let brow: String = sec.eyebrow.joined(separator: "\u{00b7}")
                parts.append("\(si):" + types + "|" + sec.heading + "|" + brow)
            }
            let css: String = parent.model.design == nil ? "0" : "1"
            return parts.joined(separator: ";") + "#" + css
        }

        func reload(force: Bool) {
            let st = structure
            guard force || st != lastStructure || lastTheme != parent.dark else { return }
            lastStructure = st
            lastTheme = parent.dark
            let base = parent.site.url.flatMap { URL(string: $0) }
            web?.loadHTMLString(document(), baseURL: base)
        }

        // MARK: Nachrichten aus der Seite

        func userContentController(_ c: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let d = message.body as? [String: Any],
                  let kind = d["kind"] as? String else { return }
            var page = parent.page

            switch kind {
            case "text":
                guard let path = d["path"] as? String,
                      let html = d["html"] as? String,
                      let (si, bi) = Self.parse(path),
                      page.sections.indices.contains(si),
                      page.sections[si].blocks.indices.contains(bi) else { return }
                let clean = BlockRenderer.sanitiseInline(html)
                guard clean != page.sections[si].blocks[bi].text else { return }
                page.sections[si].blocks[bi].fields["text"] = .string(clean)
                /* Die Struktur bleibt gleich, also zeichnet reload() nicht
                   neu und der Cursor bleibt, wo er ist. */
                parent.model.updatePage(page)

            case "heading":
                guard let path = d["path"] as? String,
                      let html = d["html"] as? String,
                      let si = Int(path), page.sections.indices.contains(si) else { return }
                page.sections[si].heading = BlockRenderer.sanitiseInline(html)
                parent.model.updatePage(page)

            case "move":
                guard let from = d["from"] as? String, let to = d["to"] as? String,
                      let (fs, fb) = Self.parse(from), let (ts, tb) = Self.parse(to),
                      page.sections.indices.contains(fs),
                      page.sections[fs].blocks.indices.contains(fb),
                      page.sections.indices.contains(ts) else { return }
                let moved = page.sections[fs].blocks.remove(at: fb)
                /* Innerhalb desselben Abschnitts verschiebt das Entfernen
                   alle folgenden Plaetze um eins nach vorn. */
                var target = tb
                if fs == ts && fb < tb { target -= 1 }
                target = max(0, min(target, page.sections[ts].blocks.count))
                page.sections[ts].blocks.insert(moved, at: target)
                parent.model.updatePage(page)

            case "delete":
                guard let path = d["path"] as? String,
                      let (si, bi) = Self.parse(path),
                      page.sections.indices.contains(si),
                      page.sections[si].blocks.indices.contains(bi) else { return }
                page.sections[si].blocks.remove(at: bi)
                parent.model.updatePage(page)

            case "select":
                parent.selection = d["path"] as? String

            default:
                break
            }
        }

        private static func parse(_ p: String) -> (Int, Int)? {
            let bits = p.split(separator: ".")
            guard bits.count == 2, let a = Int(bits[0]), let b = Int(bits[1]) else { return nil }
            return (a, b)
        }

        // MARK: Das Dokument

        private func document() -> String {
            let css = parent.model.design?.rendered() ?? ""
            let theme = parent.dark ? "dark" : "light"
            let typeable = BlockRenderer.typeableInPlace.map { "'\($0)'" }.joined(separator: ",")
            let typeableSelector = BlockRenderer.typeableInPlace
                .map { _ in "" }.joined()   // nur zur Klarheit, Auswahl passiert in JS
            _ = typeableSelector
            return """
            <!doctype html>
            <html lang="en" data-theme="\(theme)">
            <head><meta charset="utf-8">
            <meta name="viewport" content="width=device-width,initial-scale=1">
            <style>\(css)</style>
            <style>\(Self.editorCSS)</style>
            </head>
            <body>
            <main class="container" style="padding:1.4rem 1.25rem 4rem;">
              <div class="dd-wrap">
            \(BlockRenderer.editableBody(parent.page))
              </div>
            </main>
            <script>
            var TYPEABLE = [\(typeable)];
            \(Self.editorJS)
            </script>
            </body></html>
            """
        }

        // MARK: Die Bedienschicht

        /* Bewusst duenn. Ein dicker Rahmen um jeden Block waehrend der
           Arbeit veraendert, was man sieht, und dann bearbeitet man nicht
           mehr die Seite, sondern ein Bild von ihr. Deshalb nur eine
           Umrandung ohne Platzbedarf (outline, kein border) und ein Griff,
           der ausserhalb des Textflusses sitzt. */
        static let editorCSS = """
        [data-blk] { position: relative; }
        [data-blk]:hover { outline: 1px solid rgba(120,140,180,0.45); outline-offset: 4px; }
        [data-blk].sel  { outline: 2px solid var(--accent); outline-offset: 4px; }
        [data-blk].drag { opacity: 0.35; }
        .lc-grip {
          position: absolute; left: -30px; top: 0; width: 22px; height: 22px;
          display: none; align-items: center; justify-content: center;
          cursor: grab; user-select: none; border-radius: 2px;
          background: var(--surface); border: 1px solid var(--rule);
          color: var(--muted); font-size: 13px; line-height: 1;
        }
        [data-blk]:hover > .lc-grip, [data-blk].sel > .lc-grip { display: flex; }
        .lc-del {
          position: absolute; right: -30px; top: 0; width: 22px; height: 22px;
          display: none; align-items: center; justify-content: center;
          cursor: pointer; user-select: none; border-radius: 2px;
          background: var(--surface); border: 1px solid var(--rule);
          color: var(--muted); font-size: 13px; line-height: 1;
        }
        [data-blk]:hover > .lc-del, [data-blk].sel > .lc-del { display: flex; }
        .lc-del:hover { color: #C81E1E; border-color: #C81E1E; }
        [contenteditable="true"] { outline: 2px solid var(--accent); outline-offset: 4px; }
        .lc-drop { outline: 2px solid var(--accent) !important; outline-offset: 6px; }
        .lc-hint {
          position: fixed; left: 12px; bottom: 12px; z-index: 99;
          font: 11px/1.4 system-ui, sans-serif; color: var(--muted);
          background: var(--surface); border: 1px solid var(--rule);
          border-radius: 2px; padding: 5px 8px; pointer-events: none;
        }
        """

        static let editorJS = """
        (function () {
          var send = function (m) { window.webkit.messageHandlers.edit.postMessage(m); };
          var blocks = [].slice.call(document.querySelectorAll('[data-blk]'));
          var dragging = null;

          var hint = document.createElement('div');
          hint.className = 'lc-hint';
          hint.textContent = 'Click text to write. Drag the handle to move. '
                           + blocks.length + ' blocks.';
          document.body.appendChild(hint);

          function typeOf(el) {
            /* Der Blocktyp steckt nicht im HTML, also wird er aus der Form
               geschlossen: was ein Absatz oder eine Ueberschrift ist, laesst
               sich tippen, alles andere nicht. */
            var t = el.tagName.toLowerCase();
            if (t === 'p' || t === 'h3' || t === 'h4') return 'text';
            return 'other';
          }

          blocks.forEach(function (el) {
            var grip = document.createElement('span');
            grip.className = 'lc-grip';
            grip.textContent = '\\u2630';
            grip.title = 'Move';
            grip.draggable = true;
            el.appendChild(grip);

            var del = document.createElement('span');
            del.className = 'lc-del';
            del.textContent = '\\u00d7';
            del.title = 'Remove this block';
            del.addEventListener('click', function (e) {
              e.stopPropagation();
              send({ kind: 'delete', path: el.getAttribute('data-blk') });
            });
            el.appendChild(del);

            el.addEventListener('click', function (e) {
              if (e.target === grip || e.target === del) return;
              blocks.forEach(function (b) { b.classList.remove('sel'); });
              el.classList.add('sel');
              send({ kind: 'select', path: el.getAttribute('data-blk') });
              if (typeOf(el) === 'text' && el.getAttribute('contenteditable') !== 'true') {
                el.setAttribute('contenteditable', 'true');
                el.focus();
              }
            });

            el.addEventListener('blur', function () {
              if (el.getAttribute('contenteditable') !== 'true') return;
              el.removeAttribute('contenteditable');
              var html = el.innerHTML
                .replace(/<span class="lc-grip"[\\s\\S]*?<\\/span>/g, '')
                .replace(/<span class="lc-del"[\\s\\S]*?<\\/span>/g, '');
              send({ kind: 'text', path: el.getAttribute('data-blk'), html: html });
            }, true);

            grip.addEventListener('dragstart', function (e) {
              dragging = el;
              el.classList.add('drag');
              e.dataTransfer.effectAllowed = 'move';
              e.dataTransfer.setData('text/plain', el.getAttribute('data-blk'));
            });
            grip.addEventListener('dragend', function () {
              el.classList.remove('drag');
              blocks.forEach(function (b) { b.classList.remove('lc-drop'); });
              dragging = null;
            });

            el.addEventListener('dragover', function (e) {
              if (!dragging || dragging === el) return;
              e.preventDefault();
              blocks.forEach(function (b) { b.classList.remove('lc-drop'); });
              el.classList.add('lc-drop');
            });
            el.addEventListener('drop', function (e) {
              if (!dragging || dragging === el) return;
              e.preventDefault();
              send({ kind: 'move',
                     from: dragging.getAttribute('data-blk'),
                     to: el.getAttribute('data-blk') });
            });
          });

          /* Ueberschriften der Abschnitte sind auch Text. */
          [].slice.call(document.querySelectorAll('[data-sec] > h2.dd-h')).forEach(function (h) {
            var sec = h.closest('[data-sec]').getAttribute('data-sec');
            h.addEventListener('click', function () {
              h.setAttribute('contenteditable', 'true');
              h.focus();
            });
            h.addEventListener('blur', function () {
              h.removeAttribute('contenteditable');
              send({ kind: 'heading', path: sec, html: h.innerHTML });
            }, true);
          });
        })();
        """
    }
}
