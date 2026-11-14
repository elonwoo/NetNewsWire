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

/// Feed identity and display names, keyed by both the display id and the feed
/// URL. Built from `FeedSettings.feedSettings` plus the already parsed OPML;
/// name priority matches `list_feeds` (editedName → OPML text/title → feed id).
public enum FeedDirectory {
    public static func load(
        from database: ReadOnlyDatabase, opml: ParsedOPML
    ) throws -> [String: FeedInfo] {
        let rows = try database.query("SELECT feedURL, feedID, editedName FROM fs.feedSettings")
        var directory: [String: FeedInfo] = [:]
        for row in rows {
            guard row.count >= 3, let feedURL = normalizeOptional(row[0].stringValue) else {
                continue
            }
            let displayID = normalizeOptional(row[1].stringValue) ?? feedURL
            let opmlFeed =
                opml.feedsByURL[feedURL]
                ?? normalizeOptional(row[1].stringValue).flatMap { opml.feedsByURL[$0] }
            let title = normalizeOptional(row[2].stringValue) ?? opmlFeed?.name ?? displayID
            let info = FeedInfo(
                id: displayID, url: feedURL, title: title, folder: opmlFeed?.folder)
            directory[displayID] = info
            directory[feedURL] = info
        }
        return directory
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

    public static func run(arguments: [String: Value]?, context: ServerContext) throws -> String {
        let arguments = arguments ?? [:]
        try ToolArgument.rejectUnknown(
            arguments, allowed: ["feed_id", "unread_only", "limit"], tool: "list_articles")

        let feedID = try ToolArgument.string(arguments, "feed_id")
        let unreadOnly = try ToolArgument.bool(arguments, "unread_only") ?? false
        let limit = try ToolArgument.int(arguments, "limit") ?? defaultLimit
        guard (1...maximumLimit).contains(limit) else {
            throw ToolError("limit 必须在 1..\(maximumLimit) 之间，收到 \(limit)")
        }
        if let feedID, normalizeOptional(feedID) == nil {
            throw ToolError("feed_id 不能为空字符串")
        }

        let database = try ToolDatabase.open(context: context)
        let (totalMatched, items) = try database.withReadTransaction {
            () -> (Int, [ListArticlesItem]) in
            let directory = try FeedDirectory.load(from: database, opml: context.opml)
            if let feedID, directory[feedID] == nil {
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
            let whereClause =
                conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")

            let totalMatched =
                try database.scalarInt(
                    """
                    SELECT count(*)
                    FROM articles AS a
                    LEFT JOIN statuses AS st ON st.articleID = a.articleID
                    """ + whereClause,
                    binds: binds
                ) ?? 0

            var rowBinds = binds
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
                FROM articles AS a
                LEFT JOIN search AS f ON f.rowid = a.searchRowID
                LEFT JOIN statuses AS st ON st.articleID = a.articleID
                """ + whereClause + """
                 ORDER BY (a.datePublished IS NULL) ASC, a.datePublished DESC, a.articleID DESC
                 LIMIT ?
                """,
                binds: rowBinds
            )

            let items = rows.compactMap { row -> ListArticlesItem? in
                guard row.count >= 10,
                    let articleID = row[0].stringValue,
                    let articleFeedID = row[1].stringValue
                else {
                    return nil
                }
                let body = row[8].stringValue ?? ""
                let contentText = row[9].stringValue ?? ""
                let effectiveContent = body.isEmpty ? contentText : body
                let feed = directory[articleFeedID]
                return ListArticlesItem(
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
            }
            return (totalMatched, items)
        }

        var response = ListArticlesResponse(
            totalMatched: totalMatched,
            returned: items.count,
            omitted: 0,
            truncated: false,
            articles: items
        )
        return try encodeListArticlesBounded(&response)
    }
}
