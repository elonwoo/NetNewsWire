import Foundation

/// An article's position in the fixed list order
/// `datePublished DESC, articleID DESC`, with null dates last.
public struct ArticleCursorPosition: Sendable, Equatable {
    public let datePublished: Double?
    public let articleID: String

    public init(datePublished: Double?, articleID: String) {
        self.datePublished = datePublished
        self.articleID = articleID
    }
}

/// Opaque keyset cursor for the two paginated article tools.
///
/// The cursor encodes the sort position only; it never encodes an offset. A
/// filter fingerprint is stored alongside so that a cursor produced under one
/// set of filters is rejected under another. `datePublished == nil` is a
/// distinct state from any numeric date, which is what lets a traversal cross
/// the null-date boundary.
public enum ArticleCursor {
    public static let version = 1

    private struct Payload: Codable {
        var v: Int
        var k: String
        var f: String
        var d: Double?
        var i: String

        enum CodingKeys: String, CodingKey {
            case v
            case k
            case f
            case d
            case i
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(v, forKey: .v)
            try container.encode(k, forKey: .k)
            try container.encode(f, forKey: .f)
            if let d {
                try container.encode(d, forKey: .d)
            } else {
                try container.encodeNil(forKey: .d)
            }
            try container.encode(i, forKey: .i)
        }
    }

    public static func encode(
        kind: String,
        filter: String,
        position: ArticleCursorPosition,
        tool: String
    ) throws -> String {
        let payload = Payload(
            v: version, k: kind, f: filter, d: position.datePublished, i: position.articleID)
        do {
            let data = try CompactJSON.encode(payload)
            return data.base64EncodedString()
        } catch {
            throw ToolError("\(tool) 无法编码 after 游标：\(error)")
        }
    }

    public static func decode(
        _ raw: String,
        kind: String,
        filter: String,
        tool: String
    ) throws -> ArticleCursorPosition {
        guard let data = Data(base64Encoded: raw),
            let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else {
            throw ToolError("\(tool) 的 after 游标格式无效")
        }
        guard payload.v == version, payload.k == kind, payload.f == filter else {
            throw ToolError("\(tool) 的 after 游标与当前过滤条件不匹配")
        }
        return ArticleCursorPosition(datePublished: payload.d, articleID: payload.i)
    }

    /// SQL condition selecting the rows strictly after `position` in the
    /// `(datePublished DESC, articleID DESC, null last)` order. Dated rows come
    /// first; once the cursor itself is null-dated only null-dated rows remain.
    public static func positionClause(
        _ position: ArticleCursorPosition, alias: String = "a"
    ) -> (condition: String, binds: [SQLBind]) {
        if let date = position.datePublished {
            return (
                "(\(alias).datePublished IS NULL"
                    + " OR \(alias).datePublished < ?"
                    + " OR (\(alias).datePublished = ? AND \(alias).articleID < ?))",
                [.real(date), .real(date), .text(position.articleID)]
            )
        }
        return (
            "(\(alias).datePublished IS NULL AND \(alias).articleID < ?)",
            [.text(position.articleID)]
        )
    }
}

public enum ArticleFilterFingerprint {
    public static func list(
        feedID: String?, unreadOnly: Bool, sinceSeconds: Double?
    ) -> String {
        let since = sinceSeconds.map { String(Int64(($0 * 1000).rounded())) } ?? ""
        return "list_articles|feed_id=\(feedID ?? "")|unread_only=\(unreadOnly ? 1 : 0)|since=\(since)"
    }

    public static func search(query: String) -> String {
        "search_articles|query=\(query)"
    }
}
