import Foundation
import MCP

public struct FeedInfo: Sendable, Equatable {
    public let id: String
    public let url: String
    public let title: String
    public let folder: String?

    public init(id: String, url: String, title: String, folder: String?) {
        self.id = id
        self.url = url
        self.title = title
        self.folder = folder
    }
}

/// Feed identity and display names.
///
/// The known `feed_id` set is `FeedSettings.feedID` ∪ OPML `xmlUrl` ∪
/// `articles.feedID`; `feedURL` is deliberately not part of it, so a URL column
/// value can never stand in for a feed id (filtering does not fall back to
/// `articles.feedURL`). Display names still resolve through the settings row
/// that matches either column, with priority
/// editedName → OPML text/title → feed id.
public struct FeedDirectory: Sendable, Equatable {
    public let infoByID: [String: FeedInfo]
    public let knownIDs: Set<String>

    public init(infoByID: [String: FeedInfo], knownIDs: Set<String>) {
        self.infoByID = infoByID
        self.knownIDs = knownIDs
    }

    public func info(_ feedID: String) -> FeedInfo? {
        infoByID[feedID]
    }

    public func isKnown(_ feedID: String) -> Bool {
        knownIDs.contains(feedID)
    }

    public static func load(
        from database: ReadOnlyDatabase, opml: ParsedOPML
    ) throws -> FeedDirectory {
        var infoByID: [String: FeedInfo] = [:]
        var knownIDs: Set<String> = []

        let rows = try database.query("SELECT feedURL, feedID, editedName FROM fs.feedSettings")
        for row in rows {
            guard row.count >= 3 else { continue }
            let rawFeedID = normalizeOptional(row[1].stringValue)
            if let rawFeedID { knownIDs.insert(rawFeedID) }
            let rawFeedURL = normalizeOptional(row[0].stringValue)
            let displayID = rawFeedID ?? rawFeedURL
            guard let displayID else { continue }

            let lookupURL = rawFeedURL ?? displayID
            let opmlFeed =
                opml.feedsByURL[lookupURL] ?? rawFeedID.flatMap { opml.feedsByURL[$0] }
            let title = normalizeOptional(row[2].stringValue) ?? opmlFeed?.name ?? displayID
            let info = FeedInfo(
                id: displayID, url: lookupURL, title: title, folder: opmlFeed?.folder)
            // Names are looked up by the feed id used in `articles.feedID`; a
            // `feedURL` key is only a naming fallback and never grants access.
            if infoByID[displayID] == nil { infoByID[displayID] = info }
            if infoByID[lookupURL] == nil { infoByID[lookupURL] = info }
        }

        for (xmlURL, feed) in opml.feedsByURL {
            knownIDs.insert(xmlURL)
            if infoByID[xmlURL] == nil {
                infoByID[xmlURL] = FeedInfo(
                    id: xmlURL,
                    url: xmlURL,
                    title: feed.name ?? xmlURL,
                    folder: feed.folder
                )
            }
        }

        let articleFeedIDs = try database.query(
            "SELECT DISTINCT feedID FROM articles WHERE feedID IS NOT NULL AND feedID <> ''")
        for row in articleFeedIDs {
            guard let feedID = row.first?.stringValue, !feedID.isEmpty else { continue }
            knownIDs.insert(feedID)
            if infoByID[feedID] == nil {
                let opmlFeed = opml.feedsByURL[feedID]
                infoByID[feedID] = FeedInfo(
                    id: feedID,
                    url: feedID,
                    title: opmlFeed?.name ?? feedID,
                    folder: opmlFeed?.folder
                )
            }
        }

        return FeedDirectory(infoByID: infoByID, knownIDs: knownIDs)
    }
}

enum ArticleSupport {
    /// Collapses CR/LF into single spaces without changing the order of the
    /// remaining characters.
    static func flattenNewlines(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    static func firstAuthorName(fromJSON json: String?) -> String? {
        guard let json, let data = json.data(using: .utf8),
            let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
            let name = array.first?["name"] as? String
        else {
            return nil
        }
        return normalizeOptional(name)
    }

    static func authorNames(fromJSON json: String?) -> [String]? {
        guard let json, let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let array = object as? [Any]
        else {
            return nil
        }
        var names: [String] = []
        for element in array {
            guard let dictionary = element as? [String: Any], let name = dictionary["name"] as? String,
                let normalized = normalizeOptional(name)
            else {
                continue
            }
            names.append(normalized)
        }
        return names
    }
}

public enum ListArticlesTool {
    public static let defaultLimit = 20
    public static let maximumLimit = 100
    static let cursorKind = "list_articles"

    private struct Fetched {
        let item: ListArticlesItem
        let position: ArticleCursorPosition
    }

    public static func run(arguments: [String: Value]?, context: ServerContext) throws -> String {
        let arguments = arguments ?? [:]
        try ToolArgument.rejectUnknown(
            arguments, allowed: ["feed_id", "unread_only", "since", "after", "limit"],
            tool: "list_articles")

        let feedID = try ToolArgument.string(arguments, "feed_id")
        let unreadOnly = try ToolArgument.bool(arguments, "unread_only") ?? false
        let limit = try ToolArgument.int(arguments, "limit") ?? defaultLimit
        guard (1...maximumLimit).contains(limit) else {
            throw ToolError("limit 必须在 1..\(maximumLimit) 之间，收到 \(limit)")
        }
        if let feedID, normalizeOptional(feedID) == nil {
            throw ToolError("feed_id 不能为空字符串")
        }

        let sinceSeconds: Double?
        if let rawSince = try ToolArgument.string(arguments, "since") {
            guard let seconds = DateFormats.epochSeconds(fromISO8601: rawSince) else {
                throw ToolError("since 无法解析为 ISO 8601 时间：\(rawSince)")
            }
            sinceSeconds = seconds
        } else {
            sinceSeconds = nil
        }

        let filter = ArticleFilterFingerprint.list(
            feedID: feedID, unreadOnly: unreadOnly, sinceSeconds: sinceSeconds)
        let cursorPosition: ArticleCursorPosition?
        if let rawAfter = try ToolArgument.string(arguments, "after") {
            cursorPosition = try ArticleCursor.decode(
                rawAfter, kind: cursorKind, filter: filter, tool: "list_articles")
        } else {
            cursorPosition = nil
        }

        let database = try ToolDatabase.open(context: context)
        let (totalMatched, remainingMatched, fetched) = try database.withReadTransaction {
            () -> (Int, Int, [Fetched]) in
            let directory = try FeedDirectory.load(from: database, opml: context.opml)
            if let feedID, !directory.isKnown(feedID) {
                throw ToolError("未知 feed_id：\(feedID)")
            }

            var conditions: [String] = []
            var binds: [SQLBind] = []
            if let feedID {
                conditions.append("a.feedID = ?")
                binds.append(.text(feedID))
            }
            if unreadOnly {
                conditions.append("(st.articleID IS NULL OR COALESCE(st.read, 0) = 0)")
            }
            if let sinceSeconds {
                conditions.append("a.datePublished IS NOT NULL AND a.datePublished >= ?")
                binds.append(.real(sinceSeconds))
            }

            let joins = """
                FROM articles AS a
                LEFT JOIN search AS f ON f.rowid = a.searchRowID
                LEFT JOIN statuses AS st ON st.articleID = a.articleID
                """
            let whereClause =
                conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")

            let totalMatched = try database.scalarInt(
                "SELECT count(*) " + joins + whereClause, binds: binds) ?? 0

            var pageConditions = conditions
            var pageBinds = binds
            if let cursorPosition {
                let clause = ArticleCursor.positionClause(cursorPosition)
                pageConditions.append(clause.condition)
                pageBinds.append(contentsOf: clause.binds)
            }
            let pageWhereClause =
                pageConditions.isEmpty ? "" : " WHERE " + pageConditions.joined(separator: " AND ")

            let remainingMatched = try database.scalarInt(
                "SELECT count(*) " + joins + pageWhereClause, binds: pageBinds) ?? 0

            var rowBinds = pageBinds
            rowBinds.append(.integer(Int64(limit)))
            let rows = try database.query(
                """
                SELECT a.articleID,
                       a.feedID,
                       f.title,
                       a.datePublished,
                       a.url,
                       a.authors,
                       COALESCE(st.read, 0),
                       COALESCE(st.starred, 0),
                       f.body,
                       a.contentText
                """ + "\n" + joins + pageWhereClause + """
                 ORDER BY (a.datePublished IS NULL) ASC, a.datePublished DESC, a.articleID DESC
                 LIMIT ?
                """,
                binds: rowBinds
            )

            let fetched = rows.compactMap { row -> Fetched? in
                guard row.count >= 10,
                    let articleID = row[0].stringValue,
                    let articleFeedID = row[1].stringValue
                else {
                    return nil
                }
                let body = row[8].stringValue ?? ""
                let contentText = row[9].stringValue ?? ""
                let effectiveContent = body.isEmpty ? contentText : body
                let feed = directory.info(articleFeedID)
                let item = ListArticlesItem(
                    articleID: articleID,
                    title: normalizeOptional(row[2].stringValue),
                    feedID: articleFeedID,
                    feedTitle: feed?.title ?? articleFeedID,
                    folder: feed?.folder,
                    publishedAt: row[3].doubleValue.map(DateFormats.iso8601(epochSeconds:)),
                    url: row[4].stringValue,
                    read: (row[6].intValue ?? 0) != 0,
                    starred: (row[7].intValue ?? 0) != 0,
                    author: ArticleSupport.firstAuthorName(fromJSON: row[5].stringValue),
                    excerpt: ArticleSupport.flattenNewlines(
                        String(body.prefix(ContentLimits.excerptCharacters))),
                    contentChars: effectiveContent.count
                )
                let position = ArticleCursorPosition(
                    datePublished: row[3].doubleValue, articleID: articleID)
                return Fetched(item: item, position: position)
            }
            return (totalMatched, remainingMatched, fetched)
        }

        let base = ListArticlesResponse(
            totalMatched: totalMatched,
            returned: fetched.count,
            omitted: 0,
            truncated: false,
            nextCursor: nil,
            articles: fetched.map(\.item)
        )
        return try encodeListArticlesWithCursor(
            base, fetched: fetched, remainingMatched: remainingMatched, filter: filter)
    }

    /// Encodes the payload under the byte cap, then attaches `next_cursor` when
    /// rows remain after the last *returned* item. A cursor adds bytes, so the
    /// encode is repeated until the cursor anchor is stable.
    private static func encodeListArticlesWithCursor(
        _ base: ListArticlesResponse,
        fetched: [Fetched],
        remainingMatched: Int,
        filter: String
    ) throws -> String {
        var nextCursor: String?
        while true {
            var candidate = base
            candidate.nextCursor = nextCursor
            let json = try encodeListArticlesBounded(&candidate)
            guard remainingMatched > candidate.returned else {
                if nextCursor == nil { return json }
                nextCursor = nil
                continue
            }
            guard candidate.returned > 0, candidate.returned <= fetched.count else {
                throw ToolError("list_articles 无法为剩余结果生成游标")
            }
            let anchor = fetched[candidate.returned - 1].position
            let encoded = try ArticleCursor.encode(
                kind: cursorKind, filter: filter, position: anchor, tool: "list_articles")
            if encoded == nextCursor { return json }
            nextCursor = encoded
        }
    }
}
