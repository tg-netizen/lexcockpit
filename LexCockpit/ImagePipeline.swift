import AppKit
import UniformTypeIdentifiers

/// Downscale + re-encode + upload images to the site repo. CoreGraphics only.
enum ImagePipeline {

    struct Prepared {
        let data: Data
        let filename: String     // safe-slugged, extension matches encoding
    }

    /// Downscale to ≤2000 px wide and re-encode aiming for ≤500 KB.
    /// PNG is kept only for small alpha images; everything else becomes JPEG
    /// with stepping quality.
    static func prepare(data: Data, suggestedName: String) -> Prepared? {
        guard let src = NSBitmapImageRep(data: data) ?? NSImage(data: data)
            .flatMap({ $0.tiffRepresentation }).flatMap(NSBitmapImageRep.init(data:))
        else { return nil }

        let width = src.pixelsWide
        let height = src.pixelsHigh
        guard width > 0, height > 0 else { return nil }

        let maxW = 2000
        let scale = width > maxW ? Double(maxW) / Double(width) : 1.0
        let outW = Int(Double(width) * scale)
        let outH = Int(Double(height) * scale)

        guard let cg = src.cgImage else { return nil }
        var drawn: CGImage = cg
        if scale < 1.0 {
            let ctx = CGContext(data: nil, width: outW, height: outH,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.interpolationQuality = .high
            ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: outW, height: outH))
            if let scaled = ctx?.makeImage() { drawn = scaled }
        }
        let rep = NSBitmapImageRep(cgImage: drawn)

        let base = slugifyFilename(suggestedName)
        let hasAlpha = src.hasAlpha
        let limit = 500 * 1024

        // Small PNG with alpha → keep as PNG (screenshots with transparency).
        if hasAlpha, let png = rep.representation(using: .png, properties: [:]), png.count <= limit {
            return Prepared(data: png, filename: base + ".png")
        }
        // JPEG with stepping quality until under the limit (or floor reached).
        for quality in [0.85, 0.75, 0.65, 0.55, 0.45] {
            if let jpg = rep.representation(using: .jpeg,
                                            properties: [.compressionFactor: quality]),
               jpg.count <= limit || quality == 0.45 {
                return Prepared(data: jpg, filename: base + ".jpg")
            }
        }
        return nil
    }

    /// Repo path for an article image.
    static func repoPath(slug: String, filename: String) -> String {
        "assets/images/articles/\(slug)/\(filename)"
    }

    /// Upload via the GitHub Contents API. Returns the site-absolute path to
    /// embed in markdown/frontmatter.
    static func upload(repo: String, slug: String, prepared: Prepared) async throws -> String {
        let path = repoPath(slug: slug, filename: prepared.filename)
        // If the same filename exists, suffix with a short timestamp.
        var finalPath = path
        if let existing = try? await GitHubAPI.file(repo: repo, path: path), !existing.sha.isEmpty {
            let stamp = String(Int(Date().timeIntervalSince1970) % 100000)
            let dot = prepared.filename.lastIndex(of: ".") ?? prepared.filename.endIndex
            let stem = String(prepared.filename[..<dot])
            let ext = String(prepared.filename[dot...])
            finalPath = repoPath(slug: slug, filename: "\(stem)-\(stamp)\(ext)")
        }
        _ = try await GitHubAPI.putBinary(repo: repo, path: finalPath,
                                          message: "content: add image \(finalPath.components(separatedBy: "/").last ?? "")",
                                          data: prepared.data, sha: nil)
        return "/" + finalPath
    }

    private static func slugifyFilename(_ name: String) -> String {
        var stem = name
        if let dot = stem.lastIndex(of: ".") { stem = String(stem[..<dot]) }
        let slug = slugify(stem)
        return slug.isEmpty ? "image-\(Int(Date().timeIntervalSince1970) % 100000)" : slug
    }
}

extension GitHubAPI {
    /// PUT raw binary content (images) — same Contents API as text files.
    static func putBinary(repo: String, path: String, message: String, data: Data, sha: String?) async throws -> GHPutResponse {
        var payload: [String: Any] = [
            "message": message,
            "content": data.base64EncodedString(),
        ]
        if let sha = sha { payload["sha"] = sha }
        let body = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(GHPutResponse.self,
            from: try await request("/repos/\(repo)/contents/\(escape(path))", method: "PUT", body: body))
    }
}
