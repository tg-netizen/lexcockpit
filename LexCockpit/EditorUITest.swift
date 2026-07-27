import AppKit
import WebKit

/// `swift run LexCockpit --editor-uitest`
///
/// Functional battery against the REAL offscreen editor shell (same
/// WysiwygController the app uses): the Canva layer must exist (gallery,
/// bubble, "+" handle, block bar), vaulted design blocks must render as
/// non-editable cards, and programmatic insertion must produce correct
/// markdown through the vault pipeline.
enum EditorUITest {
    static func start() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            let ok = await run()
            exit(ok ? 0 : 1)
        }
        app.run()
        exit(1)
    }

    @MainActor
    static func run() async -> Bool {
        var ok = true
        func expect(_ cond: Bool, _ name: String) {
            print(cond ? "PASS  \(name)" : "FAIL  \(name)")
            if !cond { ok = false }
        }

        let body = """
        Intro paragraph for the UI test.

        <div class="pull-quote">Vaulted quote.</div>

        ## Section

        <div class="keyfacts">
        <p><strong>Key facts</strong></p>
        <ul>
        <li>One</li>
        </ul>
        </div>

        Closing paragraph.
        """

        let controller = WysiwygController()
        var waited = 0.0
        while !controller.ready && waited < 30 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 0.1
        }
        guard controller.ready else {
            print("FAIL  editor never became ready (network/CDN?)")
            return false
        }

        let peeled = BlockVault.peel(body)
        controller.load(markdown: peeled.display)
        controller.installBlocks(json: BlockKind.jsPayload)
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        let cards = await evalInt(controller,
            "document.querySelectorAll('.toastui-editor-ww-container [data-vault]').length")
        expect(cards == 2, "canvas renders both design blocks as cards (got \(cards))")

        let locked = await evalInt(controller, #"""
            Array.prototype.filter.call(
              document.querySelectorAll('.toastui-editor-ww-container [data-vault]'),
              function (el) { return el.getAttribute('contenteditable') === 'false'; }).length
            """#)
        expect(locked == 2, "block cards are locked against inline typing (got \(locked))")

        let ui = await evalBool(controller, #"""
            ['bubble', 'gallery', 'plusbtn', 'blockbar'].every(function (id) {
              return !!document.getElementById(id);
            })
            """#)
        expect(ui, "bubble + gallery + plus handle + block bar exist")

        let blocks = await evalInt(controller, "window.__blocks.length")
        expect(blocks == BlockKind.allCases.count, "gallery payload has all \(BlockKind.allCases.count) blocks (got \(blocks))")

        let previews = await evalBool(controller, #"""
            window.__blocks.every(function (b) { return b.label && b.desc && b.preview !== undefined; })
            """#)
        expect(previews, "every gallery card carries label + description + preview")

        // The gallery's real insertion path: plain-text marker at the caret
        // (survives serialization verbatim), then Swift-side substitution.
        let insErr = await evalString(controller, #"""
            (function () {
              try {
                window.__editor.focus();
                window.__editor.moveCursorToEnd();
                window.__placeMarker();
                return 'ok';
              } catch (err) { return 'ERR: ' + err.message; }
            })()
            """#)
        expect(insErr == "ok", "marker placement succeeds (\(insErr))")
        try? await Task.sleep(nanoseconds: 700_000_000)
        let after: String? = await withCheckedContinuation { cont in
            controller.currentMarkdown { cont.resume(returning: $0) }
        }
        let restored = BlockVault.restore(after ?? "", vault: peeled.vault)
        expect(restored.contains(BlockVault.insertionMarker),
               "insertion marker survives the canvas verbatim")
        let substituted = BlockVault.substituteMarker(in: restored, with: BlockKind.pullquote.markdown)
        expect(substituted.contains("<div class=\"pull-quote\">Your pull quote here.</div>")
               && !substituted.contains(BlockVault.insertionMarker),
               "marker substitution lands the real block in markdown")
        expect(substituted.contains("<div class=\"pull-quote\">Vaulted quote.</div>"),
               "existing vaulted block survives the insertion byte-identically")
        expect(substituted.contains("<p><strong>Key facts</strong></p>"),
               "multi-line keyfacts block survives byte-identically")

        print(ok ? "RESULT: editor UI battery green."
                 : "RESULT: editor UI battery has failures.")
        return ok
    }

    @MainActor
    private static func evalInt(_ c: WysiwygController, _ js: String) async -> Int {
        await withCheckedContinuation { cont in
            c.webView.evaluateJavaScript(js) { value, _ in
                cont.resume(returning: (value as? Int) ?? -1)
            }
        }
    }

    @MainActor
    private static func evalString(_ c: WysiwygController, _ js: String) async -> String {
        await withCheckedContinuation { cont in
            c.webView.evaluateJavaScript(js) { value, err in
                cont.resume(returning: (value as? String) ?? "eval-error: \(err?.localizedDescription ?? "nil")")
            }
        }
    }

    @MainActor
    private static func evalBool(_ c: WysiwygController, _ js: String) async -> Bool {
        await withCheckedContinuation { cont in
            c.webView.evaluateJavaScript(js) { value, _ in
                cont.resume(returning: (value as? Bool) ?? false)
            }
        }
    }
}
