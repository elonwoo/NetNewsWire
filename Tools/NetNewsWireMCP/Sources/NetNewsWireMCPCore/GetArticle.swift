import Foundation
import MCP

public enum GetArticleTool {
    public static let defaultMaxChars = 20000
    public static let minimumMaxChars = 500
    public static let maximumMaxChars = 32000

    private struct SelectedArticle {
        let row: [SQLValue]
        let duplicateCount: Int
    }

    public static func run(arguments: [String: Value]?, context: ServerContext) throws -> String {
        let arguments = arguments ?? [:]
        try ToolArgument.rejectUnknown(
            arguments, allowed: ["article_id", "url", "max_chars"], tool: "get_article")

        let articleID = try ToolArgument.string(arguments, "article_id")
        let url = try ToolArgument.string(arguments, "url")
        let maxChars = try ToolArgument.int(arguments, "max_chars") ?? defaultMaxChars

        switch (articleID, url) {
        case (nil, nil):
            throw ToolError("get_article 需要 article_id 或 url 之一")
        case (.some, .some):
            throw ToolError("get_article 的 article_id 与 url 只能给一个")
        default:
            break
        }
        guard (minimumMaxChars...maximumMaxChars).contains(maxChars) else {
            throw ToolError(
                "max_chars 必须在 \(minimumMaxChars)..\(maximumMaxChars) 之间，收到 \(maxChars)")
        }

        let database = try ToolDatabase.open(context: context)
        var response = try database.withReadTransaction { () -> GetArticleResponse in
            let directory = try FeedDirectory.load(from: database, opml: context.opml)
            let selected: SelectedArticle
            if let articleID {
                selected = try selectByArticleID(articleID, in: database)
            } else if let url {
                selected = try selectByURL(url, in: database)
            } else {
                throw ToolError("get_article 需要 article_id 或 url 之一")
            }
            return buildResponse(from: selected, directory: directory, maxChars: maxChars)
        }
        return try encodeGetArticleBounded(&response)
    }

    private static let selectedColumns = """
        SELECT a.articleID,
               a.feedID,
               f.title,
               a.datePublished,
               a.dateModified,
               a.url,
               a.externalURL,
               a.authors,
               f.body,
               a.contentText,
               st.dateArrived,
               COALESCE(st.read, 0),
               COALESCE(st.starred, 0)
        FROM articles AS a
        LEFT JOIN search AS f ON f.rowid = a.searchRowID
        LEFT JOIN statuses AS st ON st.articleID = a.articleID
        """

    private static func selectByArticleID(
        _ articleID: String, in database: ReadOnlyDatabase
    ) throws -> SelectedArticle {
        let rows = try database.query(
            selectedColumns + " WHERE a.articleID = ? LIMIT 1", binds: [.text(articleID)])
        guard let row = rows.first else {
            throw ToolError("找不到文章 article_id=\(articleID)")
        }
        return SelectedArticle(row: row, duplicateCount: 1)
    }

    private static func selectByURL(
        _ url: String, in database: ReadOnlyDatabase
    ) throws -> SelectedArticle {
        let byURL = try database.scalarInt(
            "SELECT count(*) FROM articles WHERE url = ?", binds: [.text(url)]) ?? 0
        if byURL > 0 {
            let rows = try database.query(
                selectedColumns + """
                     WHERE a.url = ?
                     ORDER BY (a.datePublished IS NULL) ASC, a.datePublished DESC, a.articleID DESC
                     LIMIT 1
                    """,
                binds: [.text(url)]
            )
            guard let row = rows.first else {
                throw ToolError("找不到文章 url=\(url)")
            }
            return SelectedArticle(row: row, duplicateCount: byURL)
        }

        let byExternalURL = try database.scalarInt(
            "SELECT count(*) FROM articles WHERE externalURL = ?", binds: [.text(url)]) ?? 0
        if byExternalURL > 0 {
            let rows = try database.query(
                selectedColumns + """
                     WHERE a.externalURL = ?
                     ORDER BY (a.datePublished IS NULL) ASC, a.datePublished DESC, a.articleID DESC
                     LIMIT 1
                    """,
                binds: [.text(url)]
            )
            guard let row = rows.first else {
                throw ToolError("找不到文章 url=\(url)")
            }
            return SelectedArticle(row: row, duplicateCount: byExternalURL)
        }

        throw ToolError("找不到文章 url=\(url)")
    }

    private static func buildResponse(
        from selected: SelectedArticle, directory: FeedDirectory, maxChars: Int
    ) -> GetArticleResponse {
        let row = selected.row
        let articleID = row[0].stringValue ?? ""
        let feedID = row[1].stringValue ?? ""
        let body = row[8].stringValue ?? ""
        let contentText = row[9].stringValue ?? ""

        let fullContent: String
        let contentSource: String
        if !body.isEmpty {
            fullContent = body
            contentSource = "search_index_text"
        } else if !contentText.isEmpty {
            fullContent = contentText
            contentSource = "contentText"
        } else {
            fullContent = ""
            contentSource = "none"
        }

        let totalChars = fullContent.count
        let content: String
        let truncated: Bool
        if totalChars > maxChars {
            content = String(fullContent.prefix(maxChars))
            truncated = true
        } else {
            content = fullContent
            truncated = false
        }

        let feed = directory.info(feedID)
        return GetArticleResponse(
            articleID: articleID,
            feedID: feedID,
            feedTitle: feed?.title ?? feedID,
            folder: feed?.folder,
            title: normalizeOptional(row[2].stringValue),
            url: row[5].stringValue,
            externalURL: row[6].stringValue,
            publishedAt: row[3].doubleValue.map(DateFormats.iso8601(epochSeconds:)),
            modifiedAt: row[4].doubleValue.map(DateFormats.iso8601(epochSeconds:)),
            arrivedAt: row[10].doubleValue.map(DateFormats.iso8601(epochSeconds:)),
            read: (row[11].intValue ?? 0) != 0,
            starred: (row[12].intValue ?? 0) != 0,
            authors: ArticleSupport.authorNames(fromJSON: row[7].stringValue),
            contentSource: contentSource,
            content: content,
            contentChars: content.count,
            contentTotalChars: totalChars,
            contentBytes: content.utf8.count,
            contentTruncated: truncated,
            duplicateCount: selected.duplicateCount
        )
    }
}
