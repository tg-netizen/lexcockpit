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
            let rev: String = String(parent.model.pageRevision)
            return parts.joined(separator: ";") + "#" + css + "#" + rev
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

            case "insert":
                guard let at = d["at"] as? String, let type = d["type"] as? String,
                      let (si, bi) = Self.parse(at) else { return }
                parent.model.insertBlock(type, into: page.id, section: si, at: bi)

            case "move":
                guard let from = d["from"] as? String, let to = d["to"] as? String,
                      let (fs, fb) = Self.parse(from), let (ts, tb0) = Self.parse(to),
                      page.sections.indices.contains(fs),
                      page.sections[fs].blocks.indices.contains(fb),
                      page.sections.indices.contains(ts) else { return }
                /* Unter der unteren Haelfte des Ziels heisst dahinter. Ohne
                   das kann man einen Block nie ans Ende setzen. */
                let after = (d["after"] as? Bool) ?? false
                let tb = after ? tb0 + 1 : tb0
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

        /* Der Einfuegepunkt zwischen zwei Bloecken. Er nimmt keinen Platz
           weg, solange niemand hinschaut: acht Pixel hoch mit negativem
           Rand, damit der Abstand der Seite unveraendert bleibt. */
        .lc-ins {
          position: relative; height: 8px; margin: -4px 0; z-index: 5;
        }
        .lc-ins__line {
          position: absolute; left: 0; right: 0; top: 3px; height: 2px;
          background: var(--accent); opacity: 0; transition: opacity 120ms;
        }
        .lc-ins__btn {
          position: absolute; left: 50%; top: -8px; transform: translateX(-50%);
          width: 22px; height: 22px; border-radius: 2px; opacity: 0;
          display: flex; align-items: center; justify-content: center;
          background: var(--accent); color: var(--surface);
          font: 15px/1 system-ui, sans-serif; cursor: pointer;
          transition: opacity 120ms;
        }
        .lc-ins:hover .lc-ins__line, .lc-ins:hover .lc-ins__btn,
        .lc-ins.open .lc-ins__line, .lc-ins.open .lc-ins__btn { opacity: 1; }
        .lc-pick {
          position: absolute; left: 50%; top: 20px; transform: translateX(-50%);
          display: none; flex-wrap: wrap; gap: 4px; width: 340px; z-index: 20;
          background: var(--surface); border: 1px solid var(--rule);
          border-radius: 2px; padding: 8px;
          box-shadow: 0 8px 24px rgba(0,0,0,0.18);
        }
        .lc-ins.open .lc-pick { display: flex; }
        .lc-pick button {
          font: 11px/1 system-ui, sans-serif; color: var(--ink);
          background: var(--bg); border: 1px solid var(--rule);
          border-radius: 2px; padding: 6px 8px; cursor: pointer;
        }
        .lc-pick button:hover { border-color: var(--accent); color: var(--accent); }

        /* Die Einfuegelinie beim Ziehen. Sie sagt, wo der Block landet,
           statt nur zu zeigen, worueber die Maus schwebt. */
        .lc-line-top    { box-shadow: 0 -3px 0 -1px var(--accent); }
        .lc-line-bottom { box-shadow: 0  3px 0 -1px var(--accent); }

        /* Die Textleiste. Erscheint nur bei einer Auswahl. */
        .lc-fmt {
          position: absolute; z-index: 40; display: none; gap: 2px;
          background: var(--surface); border: 1px solid var(--rule);
          border-radius: 2px; padding: 3px; align-items: center;
          box-shadow: 0 6px 18px rgba(0,0,0,0.18);
        }
        .lc-fmt.on { display: flex; }
        .lc-fmt button {
          font: 12px/1 system-ui, sans-serif; color: var(--ink);
          background: transparent; border: 0; padding: 5px 8px;
          cursor: pointer; border-radius: 2px; min-width: 26px;
        }
        .lc-fmt button:hover { background: var(--bg); }
        .lc-fmt input {
          font: 11px/1 system-ui, sans-serif; width: 190px; padding: 5px 6px;
          border: 1px solid var(--rule); border-radius: 2px;
          background: var(--bg); color: var(--ink);
        }
        """

        static let editorJS = """
        (function () {
          var send = function (m) { window.webkit.messageHandlers.edit.postMessage(m); };
          var blocks = [].slice.call(document.querySelectorAll('[data-blk]'));
          var dragging = null;

          var hint = document.createElement('div');
          hint.className = 'lc-hint';
          hint.textContent = 'Click text to write \\u00b7 drag the handle to move \\u00b7 '
                           + 'the plus between blocks adds one \\u00b7 '
                           + '\\u2318Z undoes \\u00b7 ' + blocks.length + ' blocks';
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

            /* Ober- oder unterhalb: die Linie sagt, wo der Block landet,
               statt nur zu zeigen, worueber die Maus schwebt. Ohne das
               kaeme man nie ans Ende eines Abschnitts. */
            el.addEventListener('dragover', function (e) {
              if (!dragging || dragging === el) return;
              e.preventDefault();
              blocks.forEach(function (b) {
                b.classList.remove('lc-line-top', 'lc-line-bottom');
              });
              var r = el.getBoundingClientRect();
              el.dataset.after = (e.clientY > r.top + r.height / 2) ? '1' : '0';
              el.classList.add(el.dataset.after === '1' ? 'lc-line-bottom' : 'lc-line-top');
            });
            el.addEventListener('drop', function (e) {
              if (!dragging || dragging === el) return;
              e.preventDefault();
              send({ kind: 'move',
                     from: dragging.getAttribute('data-blk'),
                     to: el.getAttribute('data-blk'),
                     after: el.dataset.after === '1' });
            });
          });

          /* ── Einfuegepunkte zwischen den Bloecken ────────────────────
             Die Geste, an der man einen Seiteneditor erkennt: zwischen
             zwei Bloecke fahren, ein Plus erscheint, und der neue Block
             landet genau dort und nicht am Ende einer Liste. */
          var TYPES = [
            ['prose', 'Paragraph'], ['lead', 'Lead'], ['heading', 'Heading'],
            ['subhead', 'Sub heading'], ['list', 'List'], ['image', 'Image'],
            ['next', 'Forward link'], ['counts', 'Count row'],
            ['gaps', 'Named gaps'], ['sources', 'Sources'],
            ['limit', 'Limit note'], ['hint', 'Hint'],
            ['table', 'Table'], ['tool', 'Instrument']
          ];

          function insertPoint(sec, index) {
            var wrap = document.createElement('div');
            wrap.className = 'lc-ins';
            var line = document.createElement('div');
            line.className = 'lc-ins__line';
            var btn = document.createElement('div');
            btn.className = 'lc-ins__btn';
            btn.textContent = '+';
            btn.title = 'Add a block here';
            var pick = document.createElement('div');
            pick.className = 'lc-pick';
            TYPES.forEach(function (t) {
              var b = document.createElement('button');
              b.textContent = t[1];
              b.addEventListener('click', function (e) {
                e.stopPropagation();
                send({ kind: 'insert', at: sec + '.' + index, type: t[0] });
              });
              pick.appendChild(b);
            });
            btn.addEventListener('click', function (e) {
              e.stopPropagation();
              var was = wrap.classList.contains('open');
              [].slice.call(document.querySelectorAll('.lc-ins'))
                .forEach(function (x) { x.classList.remove('open'); });
              if (!was) wrap.classList.add('open');
            });
            wrap.appendChild(line); wrap.appendChild(btn); wrap.appendChild(pick);
            return wrap;
          }

          [].slice.call(document.querySelectorAll('[data-sec]')).forEach(function (sec) {
            var si = sec.getAttribute('data-sec');
            var kids = [].slice.call(sec.querySelectorAll(':scope > [data-blk]'));
            kids.forEach(function (k, i) {
              sec.insertBefore(insertPoint(si, i), k);
            });
            sec.appendChild(insertPoint(si, kids.length));
          });

          document.addEventListener('click', function (e) {
            if (e.target.closest('.lc-ins')) return;
            [].slice.call(document.querySelectorAll('.lc-ins'))
              .forEach(function (x) { x.classList.remove('open'); });
          });

          /* ── Die Textleiste ─────────────────────────────────────────
             Fett, kursiv, Link. Mehr nicht: alles darueber hinaus waere
             Gestaltung im Text, und die gehoert ins Stylesheet, nicht in
             einen Absatz. */
          var fmt = document.createElement('div');
          fmt.className = 'lc-fmt';
          function fbtn(label, title, fn) {
            var b = document.createElement('button');
            b.innerHTML = label; b.title = title;
            b.addEventListener('mousedown', function (e) { e.preventDefault(); });
            b.addEventListener('click', function (e) { e.preventDefault(); fn(); });
            return b;
          }
          var linkInput = document.createElement('input');
          linkInput.type = 'text';
          linkInput.placeholder = '/pfad oder https://…';
          linkInput.style.display = 'none';
          fmt.appendChild(fbtn('<b>B</b>', 'Bold', function () {
            document.execCommand('bold');
          }));
          fmt.appendChild(fbtn('<i>I</i>', 'Italic', function () {
            document.execCommand('italic');
          }));
          fmt.appendChild(fbtn('\\u{1F517}', 'Link', function () {
            linkInput.style.display = linkInput.style.display === 'none' ? 'block' : 'none';
            if (linkInput.style.display === 'block') linkInput.focus();
          }));
          fmt.appendChild(fbtn('\\u2715', 'Remove link', function () {
            document.execCommand('unlink');
          }));
          fmt.appendChild(linkInput);
          linkInput.addEventListener('keydown', function (e) {
            if (e.key !== 'Enter') return;
            e.preventDefault();
            if (savedRange) {
              var sel = window.getSelection();
              sel.removeAllRanges(); sel.addRange(savedRange);
            }
            document.execCommand('createLink', false, linkInput.value);
            linkInput.value = ''; linkInput.style.display = 'none';
          });
          document.body.appendChild(fmt);

          var savedRange = null;
          document.addEventListener('selectionchange', function () {
            var sel = window.getSelection();
            var host = sel.anchorNode && sel.anchorNode.parentElement
                     ? sel.anchorNode.parentElement.closest('[contenteditable="true"]')
                     : null;
            if (!host || sel.isCollapsed) { fmt.classList.remove('on'); return; }
            savedRange = sel.getRangeAt(0).cloneRange();
            var r = sel.getRangeAt(0).getBoundingClientRect();
            fmt.style.left = Math.max(8, r.left + window.scrollX) + 'px';
            fmt.style.top = (r.top + window.scrollY - 40) + 'px';
            fmt.classList.add('on');
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
