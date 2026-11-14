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
