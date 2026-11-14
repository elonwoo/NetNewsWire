import Foundation

/// A failure detected before the MCP server starts serving.
///
/// `code` is one of the process exit codes defined by the implementation
/// contract (3 schema, 4 data root/account/file, 5 database, 6 OPML).
public struct StartupError: Error, Sendable, CustomStringConvertible, Equatable {
    public let code: Int32
    public let message: String

    public init(code: Int32, message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { message }
}

/// A tool-level failure. It is reported as an `isError` tool result, never as
/// a process exit code.
public struct ToolError: Error, Sendable, CustomStringConvertible, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

public struct DataRootCandidateInfo: Codable, Sendable, Equatable {
    public let path: String
    public let exists: Bool
    public let dbMtime: String?
    public let selected: Bool

    enum CodingKeys: String, CodingKey {
        case path
        case exists
        case dbMtime = "db_mtime"
        case selected
    }

    public init(path: String, exists: Bool, dbMtime: String?, selected: Bool) {
        self.path = path
        self.exists = exists
        self.dbMtime = dbMtime
        self.selected = selected
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encode(exists, forKey: .exists)
        if let dbMtime {
            try container.encode(dbMtime, forKey: .dbMtime)
        } else {
            try container.encodeNil(forKey: .dbMtime)
        }
        try container.encode(selected, forKey: .selected)
    }
}

public struct ListFeedsItem: Codable, Sendable, Equatable {
    public let feedID: String
    public let title: String
    public let folder: String?
    public let homePageURL: String?
    public let articleCount: Int
    public let unreadCount: Int
    public let latestPublishedAt: String?

    enum CodingKeys: String, CodingKey {
        case feedID = "feed_id"
        case title
        case folder
        case homePageURL = "home_page_url"
        case articleCount = "article_count"
        case unreadCount = "unread_count"
        case latestPublishedAt = "latest_published_at"
    }

    public init(
        feedID: String,
        title: String,
        folder: String?,
        homePageURL: String?,
        articleCount: Int,
        unreadCount: Int,
        latestPublishedAt: String?
    ) {
        self.feedID = feedID
        self.title = title
        self.folder = folder
        self.homePageURL = homePageURL
        self.articleCount = articleCount
        self.unreadCount = unreadCount
        self.latestPublishedAt = latestPublishedAt
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(feedID, forKey: .feedID)
        try container.encode(title, forKey: .title)
        if let folder {
            try container.encode(folder, forKey: .folder)
        } else {
            try container.encodeNil(forKey: .folder)
        }
        if let homePageURL {
            try container.encode(homePageURL, forKey: .homePageURL)
        } else {
            try container.encodeNil(forKey: .homePageURL)
        }
        try container.encode(articleCount, forKey: .articleCount)
        try container.encode(unreadCount, forKey: .unreadCount)
        if let latestPublishedAt {
            try container.encode(latestPublishedAt, forKey: .latestPublishedAt)
        } else {
            try container.encodeNil(forKey: .latestPublishedAt)
        }
    }
}

public struct ListFeedsFolder: Codable, Sendable, Equatable {
    public let name: String
    public let feedCount: Int
    public let unreadCount: Int

    enum CodingKeys: String, CodingKey {
        case name
        case feedCount = "feed_count"
        case unreadCount = "unread_count"
    }

    public init(name: String, feedCount: Int, unreadCount: Int) {
        self.name = name
        self.feedCount = feedCount
        self.unreadCount = unreadCount
    }
}

public struct ListFeedsTotals: Codable, Sendable, Equatable {
    public let feeds: Int
    public let folders: Int
    public let articles: Int
    public let unread: Int
    public let starred: Int

    public init(feeds: Int, folders: Int, articles: Int, unread: Int, starred: Int) {
        self.feeds = feeds
        self.folders = folders
        self.articles = articles
        self.unread = unread
        self.starred = starred
    }
}

public struct ListFeedsResponse: Codable, Sendable, Equatable {
    public var dataRoot: String
    public var dataRootMtime: String
    public var dataAgeSeconds: Int
    public var ambiguousDataRoots: Bool
    public var dataRootCandidates: [DataRootCandidateInfo]
    public var warnings: [String]
    public var account: String
    public var unsupportedAccounts: [String]
    public var generatedAt: String
    public var totals: ListFeedsTotals
    public var folders: [ListFeedsFolder]
    public var feeds: [ListFeedsItem]
    public var truncated: Bool
    public var omitted: Int

    enum CodingKeys: String, CodingKey {
        case dataRoot = "data_root"
        case dataRootMtime = "data_root_mtime"
        case dataAgeSeconds = "data_age_seconds"
        case ambiguousDataRoots = "ambiguous_data_roots"
        case dataRootCandidates = "data_root_candidates"
        case warnings
        case account
        case unsupportedAccounts = "unsupported_accounts"
        case generatedAt = "generated_at"
        case totals
        case folders
        case feeds
        case truncated
        case omitted
    }

    public init(
        dataRoot: String,
        dataRootMtime: String,
        dataAgeSeconds: Int,
        ambiguousDataRoots: Bool,
        dataRootCandidates: [DataRootCandidateInfo],
        warnings: [String],
        account: String,
        unsupportedAccounts: [String],
        generatedAt: String,
        totals: ListFeedsTotals,
        folders: [ListFeedsFolder],
        feeds: [ListFeedsItem],
        truncated: Bool,
        omitted: Int
    ) {
        self.dataRoot = dataRoot
        self.dataRootMtime = dataRootMtime
        self.dataAgeSeconds = dataAgeSeconds
        self.ambiguousDataRoots = ambiguousDataRoots
        self.dataRootCandidates = dataRootCandidates
        self.warnings = warnings
        self.account = account
        self.unsupportedAccounts = unsupportedAccounts
        self.generatedAt = generatedAt
        self.totals = totals
        self.folders = folders
        self.feeds = feeds
        self.truncated = truncated
        self.omitted = omitted
    }
}

public struct ListArticlesItem: Codable, Sendable, Equatable {
    public let articleID: String
    public let title: String?
    public let feedID: String
    public let feedTitle: String
    public let folder: String?
    public let publishedAt: String?
    public let url: String?
    public let read: Bool
    public let starred: Bool
    public let author: String?
    public let excerpt: String
    public let contentChars: Int

    enum CodingKeys: String, CodingKey {
        case articleID = "article_id"
        case title
        case feedID = "feed_id"
        case feedTitle = "feed_title"
        case folder
        case publishedAt = "published_at"
        case url
        case read
        case starred
        case author
        case excerpt
        case contentChars = "content_chars"
    }

    public init(
        articleID: String,
        title: String?,
        feedID: String,
        feedTitle: String,
        folder: String?,
        publishedAt: String?,
        url: String?,
        read: Bool,
        starred: Bool,
        author: String?,
        excerpt: String,
        contentChars: Int
    ) {
        self.articleID = articleID
        self.title = title
        self.feedID = feedID
        self.feedTitle = feedTitle
        self.folder = folder
        self.publishedAt = publishedAt
        self.url = url
        self.read = read
        self.starred = starred
        self.author = author
        self.excerpt = excerpt
        self.contentChars = contentChars
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(articleID, forKey: .articleID)
        if let title {
            try container.encode(title, forKey: .title)
        } else {
            try container.encodeNil(forKey: .title)
        }
        try container.encode(feedID, forKey: .feedID)
        try container.encode(feedTitle, forKey: .feedTitle)
        if let folder {
            try container.encode(folder, forKey: .folder)
        } else {
            try container.encodeNil(forKey: .folder)
        }
        if let publishedAt {
            try container.encode(publishedAt, forKey: .publishedAt)
        } else {
            try container.encodeNil(forKey: .publishedAt)
        }
        if let url {
            try container.encode(url, forKey: .url)
        } else {
            try container.encodeNil(forKey: .url)
        }
        try container.encode(read, forKey: .read)
        try container.encode(starred, forKey: .starred)
        if let author {
            try container.encode(author, forKey: .author)
        } else {
            try container.encodeNil(forKey: .author)
        }
        try container.encode(excerpt, forKey: .excerpt)
        try container.encode(contentChars, forKey: .contentChars)
    }
}

public struct ListArticlesResponse: Codable, Sendable, Equatable {
    public var totalMatched: Int
    public var returned: Int
    public var omitted: Int
    public var truncated: Bool
    public var articles: [ListArticlesItem]

    enum CodingKeys: String, CodingKey {
        case totalMatched = "total_matched"
        case returned
        case omitted
        case truncated
        case articles
    }

    public init(
        totalMatched: Int,
        returned: Int,
        omitted: Int,
        truncated: Bool,
        articles: [ListArticlesItem]
    ) {
        self.totalMatched = totalMatched
        self.returned = returned
        self.omitted = omitted
        self.truncated = truncated
        self.articles = articles
    }
}

public struct GetArticleResponse: Codable, Sendable, Equatable {
    public var articleID: String
    public var feedID: String
    public var feedTitle: String
    public var folder: String?
    public var title: String?
    public var url: String?
    public var externalURL: String?
    public var publishedAt: String?
    public var modifiedAt: String?
    public var arrivedAt: String?
    public var read: Bool
    public var starred: Bool
    public var authors: [String]?
    public var contentSource: String
    public var content: String
    public var contentChars: Int
    public var contentTotalChars: Int
    public var contentBytes: Int
    public var contentTruncated: Bool
    public var duplicateCount: Int

    enum CodingKeys: String, CodingKey {
        case articleID = "article_id"
        case feedID = "feed_id"
        case feedTitle = "feed_title"
        case folder
        case title
        case url
        case externalURL = "external_url"
        case publishedAt = "published_at"
        case modifiedAt = "modified_at"
        case arrivedAt = "arrived_at"
        case read
        case starred
        case authors
        case contentSource = "content_source"
        case content
        case contentChars = "content_chars"
        case contentTotalChars = "content_total_chars"
        case contentBytes = "content_bytes"
        case contentTruncated = "content_truncated"
        case duplicateCount = "duplicate_count"
    }

    public init(
        articleID: String,
        feedID: String,
        feedTitle: String,
        folder: String?,
        title: String?,
        url: String?,
        externalURL: String?,
        publishedAt: String?,
        modifiedAt: String?,
        arrivedAt: String?,
        read: Bool,
        starred: Bool,
        authors: [String]?,
        contentSource: String,
        content: String,
        contentChars: Int,
        contentTotalChars: Int,
        contentBytes: Int,
        contentTruncated: Bool,
        duplicateCount: Int
    ) {
        self.articleID = articleID
        self.feedID = feedID
        self.feedTitle = feedTitle
        self.folder = folder
        self.title = title
        self.url = url
        self.externalURL = externalURL
        self.publishedAt = publishedAt
        self.modifiedAt = modifiedAt
        self.arrivedAt = arrivedAt
        self.read = read
        self.starred = starred
        self.authors = authors
        self.contentSource = contentSource
        self.content = content
        self.contentChars = contentChars
        self.contentTotalChars = contentTotalChars
        self.contentBytes = contentBytes
        self.contentTruncated = contentTruncated
        self.duplicateCount = duplicateCount
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(articleID, forKey: .articleID)
        try container.encode(feedID, forKey: .feedID)
        try container.encode(feedTitle, forKey: .feedTitle)
        try encodeOptional(folder, forKey: .folder, into: &container)
        try encodeOptional(title, forKey: .title, into: &container)
        try encodeOptional(url, forKey: .url, into: &container)
        try encodeOptional(externalURL, forKey: .externalURL, into: &container)
        try encodeOptional(publishedAt, forKey: .publishedAt, into: &container)
        try encodeOptional(modifiedAt, forKey: .modifiedAt, into: &container)
        try encodeOptional(arrivedAt, forKey: .arrivedAt, into: &container)
        try container.encode(read, forKey: .read)
        try container.encode(starred, forKey: .starred)
        try encodeOptional(authors, forKey: .authors, into: &container)
        try container.encode(contentSource, forKey: .contentSource)
        try container.encode(content, forKey: .content)
        try container.encode(contentChars, forKey: .contentChars)
        try container.encode(contentTotalChars, forKey: .contentTotalChars)
        try container.encode(contentBytes, forKey: .contentBytes)
        try container.encode(contentTruncated, forKey: .contentTruncated)
        try container.encode(duplicateCount, forKey: .duplicateCount)
    }

    private func encodeOptional<T: Encodable>(
        _ value: T?, forKey key: CodingKeys, into container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        if let value {
            try container.encode(value, forKey: key)
        } else {
            try container.encodeNil(forKey: key)
        }
    }
}

public enum DateFormats {
    /// UTC ISO-8601 without fractional seconds, e.g. `2026-11-15T00:19:54Z`.
    public static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    public static func iso8601(epochSeconds: Double) -> String {
        iso8601(Date(timeIntervalSince1970: epochSeconds))
    }
}

public func normalizeOptional(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : value
}
