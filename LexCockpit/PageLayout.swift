import Foundation

/*  PageLayout.swift — the page as movable parts
 *  ═══════════════════════════════════════════════════════════════════
 *  A page on the website is HTML, and HTML is not something anyone
 *  should have to move around by hand to reorder two paragraphs. So the
 *  body of a page lives in data/pages/<id>.json as an ordered list of
 *  sections, each an ordered list of blocks, and scripts/build-pages.js
 *  renders that between two markers in the page. This file is the app's
 *  side of that arrangement.
 *
 *  ── Why the model is dictionary-backed and not a neat struct ──────────
 *  A neat Codable struct knows exactly the fields it was written with,
 *  and silently drops everything else on the way back out. That is fine
 *  until the generator grows a field this build has never heard of, at
 *  which point saving a page from an older app quietly deletes it. So a
 *  block keeps its whole JSON object and the editor writes into it.
 *  Nothing this app does not understand is ever removed by it.
 */

// MARK: - A JSON value that survives a round trip

/// Enough of JSON to hold a page file exactly as it was read.
indirect enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Double.self) { self = .number(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported JSON")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v):
            /* Whole numbers go out without a decimal point. A page file
               that gains ".0" on every integer each time it is saved is a
               diff nobody can read. */
            if v == v.rounded() && abs(v) < 1e15 { try c.encode(Int(v)) } else { try c.encode(v) }
        case .bool(let v):   try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v):  try c.encode(v)
        case .null:          try c.encodeNil()
        }
    }

    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }

    /// Strings out of an array of strings, ignoring anything else in it.
    var stringList: [String] { (arrayValue ?? []).compactMap(\.stringValue) }
}

// MARK: - Blocks

/// One block of a page. Its identity is a UUID made when it is read, so
/// SwiftUI can track it through a reorder; the identity is never written
/// to the file.
struct PageBlock: Identifiable, Equatable {
    let id = UUID()
    var fields: [String: JSONValue]

    var type: String { fields["type"]?.stringValue ?? "unknown" }

    /// Every block type this build can edit as fields rather than as raw
    /// JSON. Anything else still shows, still moves, and is written back
    /// exactly as it came in.
    static let editable: [String] = [
        "lead", "prose", "subhead", "limit", "hint",
        "next", "counts", "image", "gaps", "sources", "table", "tool"
    ]

    var isEditable: Bool { Self.editable.contains(type) }

    /// The line shown in the list. Never empty: a block with no text still
    /// has to be findable, or moving it is guesswork.
    var summary: String {
        switch type {
        case "lead", "prose", "subhead", "limit", "hint":
            return text
        case "next":
            return (fields["label"]?.stringValue ?? "") + "  ->  "
                 + (fields["href"]?.stringValue ?? "")
        case "counts":
            return (fields["items"]?.stringList ?? []).joined(separator: " · ")
        case "image":
            return fields["src"]?.stringValue ?? "(no file)"
        case "gaps":
            let n = (fields["items"]?.arrayValue ?? []).count
            return (fields["heading"]?.stringValue ?? "") + "  (\(n))"
        case "sources":
            let n = (fields["items"]?.arrayValue ?? []).count
            return (fields["summary"]?.stringValue ?? "Sources") + "  (\(n))"
        case "table":
            let cols = (fields["columns"]?.stringList ?? []).count
            let rows = (fields["rows"]?.arrayValue ?? []).count
            return "\(cols) columns, \(rows) rows"
        case "tool":
            return fields["attribute"]?.stringValue ?? "(no instrument)"
        case "html":
            let raw = fields["raw"]?.stringValue ?? ""
            return String(raw.prefix(80)).replacingOccurrences(of: "\n", with: " ")
        default:
            return "(\(type))"
        }
    }

    /// The main text of a text block, empty for the others.
    var text: String {
        get { fields["text"]?.stringValue ?? "" }
        set { fields["text"] = .string(newValue) }
    }

    var label: String {
        switch type {
        case "lead":    return "Lead paragraph"
        case "prose":   return "Paragraph"
        case "subhead": return "Sub heading"
        case "limit":   return "Limit note"
        case "hint":    return "Hint"
        case "next":    return "Forward link"
        case "counts":  return "Count row"
        case "image":   return "Image"
        case "gaps":    return "Named gaps"
        case "sources": return "Sources"
        case "table":   return "Table"
        case "tool":    return "Instrument"
        case "html":    return "Raw HTML"
        default:        return type
        }
    }

    static func == (a: PageBlock, b: PageBlock) -> Bool { a.id == b.id && a.fields == b.fields }

    /// A fresh block of a type, with the fields that type needs.
    static func make(_ type: String) -> PageBlock {
        var f: [String: JSONValue] = ["type": .string(type)]
        switch type {
        case "lead", "prose", "subhead", "limit", "hint":
            f["text"] = .string("")
        case "next":
            f["label"] = .string(""); f["href"] = .string("/")
        case "counts":
            f["items"] = .array([])
        case "image":
            f["src"] = .string(""); f["alt"] = .string("")
        case "gaps":
            f["heading"] = .string(""); f["items"] = .array([])
        case "sources":
            f["summary"] = .string("Sources and method")
            f["note"] = .string(""); f["items"] = .array([])
        case "table":
            f["columns"] = .array([]); f["rows"] = .array([])
        case "tool":
            f["attribute"] = .string(""); f["cls"] = .string("")
        default:
            break
        }
        return PageBlock(fields: f)
    }
}

// MARK: - Sections and pages

struct PageSection: Identifiable, Equatable {
    let id = UUID()
    var fields: [String: JSONValue]
    var blocks: [PageBlock]

    var sectionID: String {
        get { fields["id"]?.stringValue ?? "" }
        set { fields["id"] = .string(newValue) }
    }
    var heading: String {
        get { fields["heading"]?.stringValue ?? "" }
        set { fields["heading"] = .string(newValue) }
    }
    var eyebrow: [String] {
        get { fields["eyebrow"]?.stringList ?? [] }
        set { fields["eyebrow"] = .array(newValue.map { .string($0) }) }
    }

    static func == (a: PageSection, b: PageSection) -> Bool {
        a.id == b.id && a.fields == b.fields && a.blocks == b.blocks
    }
}

struct SitePage: Identifiable, Equatable {
    /// The file name without .json, which is also the id in the file.
    let id: String
    /// data/pages/<id>.json
    let path: String
    /// The SHA of the file as read, needed to write it back without
    /// overwriting somebody else's change.
    var sha: String?
    var fields: [String: JSONValue]
    var sections: [PageSection]

    var title: String { fields["title"]?.stringValue ?? id }
    var target: String { fields["target"]?.stringValue ?? "" }

    var blockCount: Int { sections.reduce(0) { $0 + $1.blocks.count } }

    // MARK: Reading

    static func parse(path: String, sha: String?, json: String) throws -> SitePage {
        guard let data = json.data(using: .utf8) else {
            throw NSError(domain: "SitePage", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "not readable as text"])
        }
        let root = try JSONDecoder().decode([String: JSONValue].self, from: data)
        let sections: [PageSection] = (root["sections"]?.arrayValue ?? []).compactMap { s in
            guard var obj = s.objectValue else { return nil }
            let blocks = (obj["blocks"]?.arrayValue ?? []).compactMap { b -> PageBlock? in
                guard let o = b.objectValue else { return nil }
                return PageBlock(fields: o)
            }
            obj.removeValue(forKey: "blocks")
            return PageSection(fields: obj, blocks: blocks)
        }
        var top = root
        top.removeValue(forKey: "sections")
        let name = (path as NSString).lastPathComponent
            .replacingOccurrences(of: ".json", with: "")
        return SitePage(id: name, path: path, sha: sha, fields: top, sections: sections)
    }

    // MARK: Writing

    /// Back to JSON, with every field that came in still in it.
    func encoded() throws -> String {
        var root = fields
        root["sections"] = .array(sections.map { sec in
            var o = sec.fields
            o["blocks"] = .array(sec.blocks.map { .object($0.fields) })
            return .object(o)
        })
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try enc.encode(root)
        return (String(data: data, encoding: .utf8) ?? "") + "\n"
    }
}
