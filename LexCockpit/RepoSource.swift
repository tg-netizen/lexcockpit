import Foundation
import AppKit

/*  RepoSource.swift — der Ordner auf diesem Mac, sonst GitHub
 *  ═══════════════════════════════════════════════════════════════════
 *  Bis hierher las die App das Repo ausschliesslich ueber die GitHub-API.
 *  Das hiess: was nicht gepusht ist, existiert fuer sie nicht. Wer eine
 *  Seite umstellt und sie im Layout-Bereich sucht, findet nichts und
 *  haelt den Bereich fuer kaputt, obwohl nur ein Push fehlt. Genau das
 *  ist heute passiert.
 *
 *  Die Schleife war also: aendern, committen, pushen, in der App
 *  aktualisieren, nachsehen. Vier Schritte, von denen drei nichts mit der
 *  Aenderung zu tun haben.
 *
 *  Liegt das Repo auf diesem Mac, ist es der naheliegendste Ort, es zu
 *  lesen. Also: ein Ordner-Lesezeichen je Projekt. Ist eines gesetzt,
 *  wird lokal gelesen und geschrieben, unmittelbar, ohne Netz und ohne
 *  Token. Ist keines gesetzt, bleibt alles wie es war.
 *
 *  ── Was das Schreiben bedeutet ────────────────────────────────────────
 *  Lokal schreiben heisst: die Datei im Arbeitsverzeichnis aendert sich,
 *  mehr nicht. Kein Commit, kein Push. Das ist Absicht. Wer committet,
 *  entscheidet, was in die Geschichte kommt, und diese App hat kein
 *  Urteil darueber. Die Aenderung erscheint in GitHub Desktop wie jede
 *  andere und wird dort abgeschickt.
 */

enum RepoSource {

    // MARK: Welche Quelle

    static func folderKey(_ siteID: String) -> String { "repo-folder-" + siteID }

    /// Der lokale Ordner dieses Projekts, sofern der Nutzer einen erlaubt
    /// hat und er noch da ist.
    static func localRoot(for site: SiteProject) -> URL? {
        guard let url = BookmarkStore.resolve(folderKey(site.id)) else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue else { return nil }
        return url
    }

    static func isLocal(_ site: SiteProject) -> Bool { localRoot(for: site) != nil }

    /// Woher die Zahlen kommen, in einem Wort, fuer die Herkunftszeilen.
    static func label(for site: SiteProject) -> String {
        if let root = localRoot(for: site) { return root.lastPathComponent }
        return site.repo ?? "github"
    }

    /// Den Ordner auswaehlen lassen. Gibt zurueck, ob einer gesetzt wurde.
    @MainActor static func chooseFolder(for site: SiteProject) -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use this folder"
        panel.message = "Choose the folder that holds this project's repository. "
                      + "The app will read and write files there instead of going "
                      + "through GitHub. It never commits or pushes."
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        /* Eine Plausibilitaetspruefung, damit nicht der Downloads-Ordner
           zum Repo erklaert wird. */
        let marker = url.appendingPathComponent(".git")
        guard FileManager.default.fileExists(atPath: marker.path) else {
            let a = NSAlert()
            a.messageText = "That folder is not a git repository."
            a.informativeText = "There is no .git in \(url.lastPathComponent). "
                              + "Choose the folder that holds the website itself."
            a.runModal()
            return false
        }
        BookmarkStore.store(url, key: folderKey(site.id))
        return true
    }

    @MainActor static func forgetFolder(for site: SiteProject) {
        BookmarkStore.forget(folderKey(site.id))
    }

    // MARK: Lesen

    struct FileRead {
        let text: String
        /// Nur bei GitHub belegt; lokal gibt es keine SHA und es braucht
        /// auch keine, weil niemand dazwischenschreiben kann.
        let sha: String?
    }

    static func read(_ path: String, site: SiteProject) async throws -> FileRead {
        if let root = localRoot(for: site) {
            let url = root.appendingPathComponent(path)
            let scoped = root.startAccessingSecurityScopedResource()
            defer { if scoped { root.stopAccessingSecurityScopedResource() } }
            return FileRead(text: try String(contentsOf: url, encoding: .utf8), sha: nil)
        }
        guard let repo = site.repo, !repo.isEmpty else {
            throw NSError(domain: "RepoSource", code: 1, userInfo: [
                NSLocalizedDescriptionKey:
                    "This project has neither a local folder nor a repo configured."])
        }
        let f = try await GitHubAPI.file(repo: repo, path: path)
        guard let text = f.decodedText() else {
            throw NSError(domain: "RepoSource", code: 2, userInfo: [
                NSLocalizedDescriptionKey: path + " came back but is not readable as text."])
        }
        return FileRead(text: text, sha: f.sha)
    }

    /// Alle Dateipfade des Repos, relativ zur Wurzel.
    static func list(site: SiteProject) async throws -> [String] {
        if let root = localRoot(for: site) {
            let scoped = root.startAccessingSecurityScopedResource()
            defer { if scoped { root.stopAccessingSecurityScopedResource() } }
            var out: [String] = []
            let skip: Set<String> = [".git", "node_modules", ".build", "dist", ".netlify"]
            let fm = FileManager.default
            guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                        options: [.skipsHiddenFiles]) else { return [] }
            for case let url as URL in e {
                if skip.contains(url.lastPathComponent) {
                    e.skipDescendants()
                    continue
                }
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
                if isDir == true { continue }
                let full = url.standardizedFileURL.path
                let base = root.standardizedFileURL.path
                if full.hasPrefix(base) {
                    out.append(String(full.dropFirst(base.count).drop(while: { $0 == "/" })))
                }
            }
            return out.sorted()
        }
        guard let repo = site.repo, !repo.isEmpty else { return [] }
        return try await GitHubAPI.tree(repo: repo)
            .filter { $0.type == "blob" }.map(\.path)
    }

    // MARK: Schreiben

    /// Gibt die neue SHA zurueck, wenn ueber GitHub geschrieben wurde.
    @discardableResult
    static func write(_ path: String, text: String, sha: String?,
                      message: String, site: SiteProject) async throws -> String? {
        if let root = localRoot(for: site) {
            let url = root.appendingPathComponent(path)
            let scoped = root.startAccessingSecurityScopedResource()
            defer { if scoped { root.stopAccessingSecurityScopedResource() } }
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return nil
        }
        guard let repo = site.repo, !repo.isEmpty else {
            throw NSError(domain: "RepoSource", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No local folder and no repo configured."])
        }
        let res = try await GitHubAPI.put(repo: repo, path: path,
                                          message: message, text: text, sha: sha)
        return res.content?.sha
    }
}

// MARK: - Die Leiste, die sagt woher

import SwiftUI

/*  Woher die App gerade liest, und wie man das aendert.
 *
 *  Das steht sichtbar da und nicht in den Einstellungen, weil es die
 *  Antwort auf die haeufigste Verwirrung ist: "meine Aenderung ist nicht
 *  in der App". Wer sieht, dass die App von GitHub liest, weiss sofort,
 *  dass ein Push fehlt, statt den Bereich fuer kaputt zu halten.
 */
struct RepoSourceBar: View {
    let site: SiteProject
    /// Wird gerufen, wenn sich die Quelle geaendert hat: der Aufrufer
    /// laedt dann neu.
    var onChange: () -> Void
    @State private var localName: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: localName == nil ? "cloud" : "folder")
                .font(.system(size: 11))
                .foregroundColor(.textSecondary)
            if let name = localName {
                Text("Reading and writing the folder " + name)
                    .font(.system(size: 11)).foregroundColor(.textSecondary)
                Text("no push needed")
                    .font(.system(size: 10)).foregroundColor(.statusGreen)
                Button("Use GitHub instead") {
                    RepoSource.forgetFolder(for: site)
                    refresh(); onChange()
                }
                .buttonStyle(.plain).foregroundColor(.accentNavy).font(.system(size: 11))
            } else {
                Text("Reading " + (site.repo ?? "github") + " over the network")
                    .font(.system(size: 11)).foregroundColor(.textSecondary)
                Text("only what is pushed")
                    .font(.system(size: 10)).foregroundColor(.statusAmber)
                Button("Use the folder on this Mac…") {
                    if RepoSource.chooseFolder(for: site) { refresh(); onChange() }
                }
                .buttonStyle(.plain).foregroundColor(.accentNavy).font(.system(size: 11))
            }
            Spacer()
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        localName = RepoSource.localRoot(for: site)?.lastPathComponent
    }
}
