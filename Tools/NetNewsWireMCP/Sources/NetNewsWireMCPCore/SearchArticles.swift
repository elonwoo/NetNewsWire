import Foundation
import MCP

/// Query classification for `search_articles`.
///
/// Tokens are split on whitespace and then on character class: ASCII
/// alphanumeric runs go to FTS, CJK runs go to LIKE, and the two never cross.
/// Everything else (punctuation, symbols, other scripts) only acts as a
/// separator.
public struct SearchTerms: Sendable, Equatable {
    public let ascii: [String]
    public let cjk: [String]

    public var hasTerms: Bool { !ascii.isEmpty || !cjk.isEmpty }

    public var mode: String {
        if ascii.isEmpty { return "substring" }
        if cjk.isEmpty { return "terms" }
        return "hybrid"
    }

    /// FTS4 MATCH expression: each ASCII run quoted and joined by spaces
    /// (implicit AND), at most 20 terms. Operators such as AND/OR/NOT/NEAR are
    /// therefore plain literal words.
    public var ftsQuery: String? {
        guard !ascii.isEmpty else { return nil }
        return ascii.map { "\"\($0)\"" }.joined(separator: " ")
    }

    /// `%term%` patterns with `%`, `_` and `\` escaped for `ESCAPE '\'`.
    public var likePatterns: [String] {
        cjk.map { term in
            var escaped = "%"
            for character in term {
                if character == "\\" || character == "%" || character == "_" {
                    escaped.append("\\")
                }
                escaped.append(character)
            }
            escaped.append("%")
            return escaped
        }
    }

    public static let maximumASCIITerms = 20

    public static func parse(_ query: String) -> SearchTerms {
        var ascii: [String] = []
        var cjk: [String] = []

        for token in query.split(whereSeparator: { $0.isWhitespace }) {
            var run = ""
            var runKind: CharacterKind = .other

            func flush() {
                guard !run.isEmpty else { return }
                switch runKind {
                case .ascii:
                    if ascii.count < maximumASCIITerms { ascii.append(run) }
                case .cjk:
                    cjk.append(run)
                case .other:
                    break
                }
                run = ""
                runKind = .other
            }

            for character in token {
                let kind = classify(character)
                if kind != runKind {
                    flush()
                    runKind = kind
                }
                if kind != .other {
                    run.append(character)
                }
            }
            flush()
        }

        return SearchTerms(ascii: ascii, cjk: cjk)
    }

    enum CharacterKind: Equatable {
        case ascii
        case cjk
        case other
    }

    static func classify(_ character: Character) -> CharacterKind {
        guard character.unicodeScalars.count == 1,
            let scalar = character.unicodeScalars.first?.value
        else {
            return .other
        }
        switch scalar {
        case 48...57, 65...90, 97...122:
            return .ascii
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
            return .cjk
        default:
            return .other
        }
    }
}

public enum SearchArticlesTool {
    public static let defaultLimit = 20
    public static let maximumLimit = 50
    public static let maximumQueryCharacters = 200
    public static let defaultLikeBudgetMilliseconds = 3000

    public static func run(
        arguments: [String: Value]?,
        context: ServerContext,
        likeBudgetMilliseconds: Int = defaultLikeBudgetMilliseconds
    ) throws -> String {
        let arguments = arguments ?? [:]
        try ToolArgument.rejectUnknown(
            arguments, allowed: ["query", "limit"], tool: "search_articles")

        guard let rawQuery = try ToolArgument.string(arguments, "query") else {
            throw ToolError("search_articles 需要 query 参数")
        }
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            throw ToolError("query 不能为空")
        }
        guard query.count <= maximumQueryCharacters else {
            throw ToolError("query 必须在 \(maximumQueryCharacters) 个字符以内，收到 \(query.count)")
        }

        let limit = try ToolArgument.int(arguments, "limit") ?? defaultLimit
        guard (1...maximumLimit).contains(limit) else {
            throw ToolError("limit 必须在 1..\(maximumLimit) 之间，收到 \(limit)")
        }

        let terms = SearchTerms.parse(query)
        guard terms.hasTerms else {
            throw ToolError("查询没有可检索的词项")
        }

        let database = try ToolDatabase.open(context: context)
        let budget = SQLiteProgressBudget(milliseconds: likeBudgetMilliseconds)

        let totalMatched: Int
        let items: [SearchArticlesItem]
        do {
            (totalMatched, items) = try database.withReadTransaction {
                () -> (Int, [SearchArticlesItem]) in
                let directory = try FeedDirectory.load(from: database, opml: context.opml)
                let work = { () -> (Int, [SearchArticlesItem]) in
                    try execute(
                        terms: terms, limit: limit, database: database, directory: directory)
                }
                if terms.cjk.isEmpty {
                    return try work()
                }
                return try database.withProgressBudget(budget, work)
            }
        } catch let error as DatabaseError {
            if budget.didInterrupt {
                throw ToolError(
                    "检索超时：LIKE 检索超过 \(likeBudgetMilliseconds) ms 预算，请缩小查询范围")
            }
            throw ToolError(error.description)
        }

        var response = SearchArticlesResponse(
            query: query,
            modeUsed: terms.mode,
            totalMatched: totalMatched,
            returned: items.count,
            omitted: 0,
            truncated: false,
            articles: items
        )
        return try encodeSearchArticlesBounded(&response)
    }

    private static func execute(
        terms: SearchTerms,
        limit: Int,
        database: ReadOnlyDatabase,
        directory: FeedDirectory
    ) throws -> (Int, [SearchArticlesItem]) {
        var conditions: [String] = []
        var binds: [SQLBind] = []

        if let ftsQuery = terms.ftsQuery {
            conditions.append("a.searchRowID IN (SELECT docid FROM search WHERE search MATCH ?)")
            binds.append(.text(ftsQuery))
        }
        for pattern in terms.likePatterns {
            conditions.append("(f.title LIKE ? ESCAPE '\\' OR f.body LIKE ? ESCAPE '\\')")
            binds.append(.text(pattern))
            binds.append(.text(pattern))
        }
        let whereClause = conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")

        let joins = """
            FROM articles AS a
            LEFT JOIN search AS f ON f.rowid = a.searchRowID
            LEFT JOIN statuses AS st ON st.articleID = a.articleID
            """

        let totalMatched =
            try database.scalarInt("SELECT count(*) " + joins + whereClause, binds: binds) ?? 0

        var rowBinds = binds
        rowBinds.append(.integer(Int64(limit)))
        let rows = try database.query(
            """
            SELECT a.articleID,
                   a.feedID,
                   f.title,
                   a.datePublished,
                   a.url,
                   COALESCE(st.read, 0),
                   COALESCE(st.starred, 0),
                   f.body
            """ + "\n" + joins + whereClause + """
             ORDER BY (a.datePublished IS NULL) ASC, a.datePublished DESC, a.articleID DESC
             LIMIT ?
            """,
            binds: rowBinds
        )

        let items = rows.compactMap { row -> SearchArticlesItem? in
            guard row.count >= 8,
                let articleID = row[0].stringValue,
                let feedID = row[1].stringValue
            else {
                return nil
            }
            let feed = directory.info(feedID)
            return SearchArticlesItem(
                articleID: articleID,
                title: normalizeOptional(row[2].stringValue),
                feedID: feedID,
                feedTitle: feed?.title ?? feedID,
                publishedAt: row[3].doubleValue.map(DateFormats.iso8601(epochSeconds:)),
                url: row[4].stringValue,
                read: (row[5].intValue ?? 0) != 0,
                starred: (row[6].intValue ?? 0) != 0,
                snippet: snippet(
                    title: row[2].stringValue, body: row[7].stringValue, terms: terms)
            )
        }
        return (totalMatched, items)
    }

    /// The first hit is looked up in `search.title`, then in `search.body`;
    /// hybrid queries prefer the CJK terms' position. The window is 80
    /// characters on each side, newlines are flattened, and the result never
    /// exceeds 400 characters. When nothing hits, the body's beginning is used.
    static func snippet(title: String?, body: String?, terms: SearchTerms) -> String {
        let preferred = terms.cjk.isEmpty ? terms.ascii : terms.cjk
        let fallback = terms.cjk.isEmpty ? [] : terms.ascii

        if let title, !title.isEmpty, let hit = firstHit(in: title, terms: preferred) {
            return window(title, around: hit)
        }
        if let body, let hit = firstHit(in: body, terms: preferred) {
            return window(body, around: hit)
        }
        if let title, !title.isEmpty, let hit = firstHit(in: title, terms: fallback) {
            return window(title, around: hit)
        }
        if let body, let hit = firstHit(in: body, terms: fallback) {
            return window(body, around: hit)
        }

        let source = body ?? ""
        let prefix = String(source.prefix(ContentLimits.snippetMaximumCharacters))
        return String(
            ArticleSupport.flattenNewlines(prefix).prefix(ContentLimits.snippetMaximumCharacters))
    }

    private static func firstHit(in text: String, terms: [String]) -> String.Index? {
        var best: String.Index?
        for term in terms where !term.isEmpty {
            guard let range = text.range(of: term, options: [.caseInsensitive]) else { continue }
            if let current = best {
                if range.lowerBound < current { best = range.lowerBound }
            } else {
                best = range.lowerBound
            }
        }
        return best
    }

    private static func window(_ text: String, around hit: String.Index) -> String {
        let offset = text.distance(from: text.startIndex, to: hit)
        let startOffset = max(0, offset - ContentLimits.snippetRadius)
        let start = text.index(text.startIndex, offsetBy: startOffset)
        let remaining = text.distance(from: start, to: text.endIndex)
        let length = min(remaining, ContentLimits.snippetRadius * 2 + 1)
        let end = text.index(start, offsetBy: length)
        let raw = ArticleSupport.flattenNewlines(String(text[start..<end]))
        return String(raw.prefix(ContentLimits.snippetMaximumCharacters))
    }
}
