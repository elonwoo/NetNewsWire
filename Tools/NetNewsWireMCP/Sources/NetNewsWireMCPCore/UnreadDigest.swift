import Foundation
import MCP

public enum UnreadDigestTool {
    public static let defaultDays = 1
    public static let maximumDays = 90
    public static let maxArticlesPerFeed = 3

    private struct FeedAggregate {
        let unreadTotal: Int
        let unreadInWindow: Int
        let latestPublished: Double?
    }

    public static func run(
        arguments: [String: Value]?,
        context: ServerContext,
        now: Date = Date()
    ) throws -> String {
        let arguments = arguments ?? [:]
        try ToolArgument.rejectUnknown(arguments, allowed: ["days"], tool: "unread_digest")

        let days = try ToolArgument.int(arguments, "days") ?? defaultDays
        guard (1...maximumDays).contains(days) else {
            throw ToolError("days 必须在 1..\(maximumDays) 之间，收到 \(days)")
        }

        let until = now.timeIntervalSince1970
        let since = until - Double(days * 86400)

        let database = try ToolDatabase.open(context: context)
        let snapshot: (totals: UnreadDigestTotals, feeds: [UnreadDigestFeed])
        do {
            snapshot = try database.withReadTransaction {
                let directory = try FeedDirectory.load(from: database, opml: context.opml)
                let unreadTotal = try database.scalarInt(
                    """
                    SELECT count(*)
                    FROM articles AS a
                    LEFT JOIN statuses AS st ON st.articleID = a.articleID
                    WHERE a.feedID IS NOT NULL AND a.feedID <> ''
                      AND (st.articleID IS NULL OR COALESCE(st.read, 0) = 0)
                    """
                ) ?? 0
                let unreadInWindow = try database.scalarInt(
                    """
                    SELECT count(*)
                    FROM articles AS a
                    LEFT JOIN statuses AS st ON st.articleID = a.articleID
                    WHERE a.feedID IS NOT NULL AND a.feedID <> ''
                      AND a.datePublished IS NOT NULL
                      AND a.datePublished >= ? AND a.datePublished <= ?
                      AND (st.articleID IS NULL OR COALESCE(st.read, 0) = 0)
                    """,
                    binds: [.real(since), .real(until)]
                ) ?? 0
                let articlesInWindow = try database.scalarInt(
                    """
                    SELECT count(*)
                    FROM articles
                    WHERE feedID IS NOT NULL AND feedID <> ''
                      AND datePublished IS NOT NULL
                      AND datePublished >= ? AND datePublished <= ?
                    """,
                    binds: [.real(since), .real(until)]
                ) ?? 0

                let aggregates = try loadAggregates(
                    from: database, since: since, until: until)
                let details = try loadDetails(from: database, since: since, until: until)

                var ranked: [(feed: UnreadDigestFeed, latest: Double?)] = []
                for (feedID, aggregate) in aggregates where aggregate.unreadInWindow > 0 {
                    let info = directory.info(feedID)
                    ranked.append(
                        (
                            UnreadDigestFeed(
                                feedID: feedID,
                                title: info?.title ?? feedID,
                                folder: info?.folder,
                                unreadTotal: aggregate.unreadTotal,
                                unreadInWindow: aggregate.unreadInWindow,
                                latestPublishedAt: aggregate.latestPublished.map(
                                    DateFormats.iso8601(epochSeconds:)),
                                articles: details[feedID] ?? []
                            ),
                            aggregate.latestPublished
                        )
                    )
                }

                ranked.sort { left, right in
                    if left.feed.unreadInWindow != right.feed.unreadInWindow {
                        return left.feed.unreadInWindow > right.feed.unreadInWindow
                    }
                    switch (left.latest, right.latest) {
                    case let (leftValue?, rightValue?) where leftValue != rightValue:
                        return leftValue > rightValue
                    case (nil, .some):
                        return false
                    case (.some, nil):
                        return true
                    default:
                        return left.feed.feedID < right.feed.feedID
                    }
                }

                let totals = UnreadDigestTotals(
                    unreadTotal: unreadTotal,
                    unreadInWindow: unreadInWindow,
                    articlesInWindow: articlesInWindow,
                    unreadFeeds: ranked.count
                )
                return (totals, ranked.map(\.feed))
            }
        } catch let error as DatabaseError {
            throw ToolError(error.description)
        }

        var response = UnreadDigestResponse(
            window: UnreadDigestWindow(
                since: DateFormats.iso8601(epochSeconds: since),
                until: DateFormats.iso8601(epochSeconds: until)
            ),
            totals: snapshot.totals,
            feeds: snapshot.feeds,
            truncated: false,
            omittedFeeds: 0,
            omittedUnreadInWindow: 0
        )
        return try encodeUnreadDigestBounded(&response)
    }

    private static func loadAggregates(
        from database: ReadOnlyDatabase, since: Double, until: Double
    ) throws -> [String: FeedAggregate] {
        let rows = try database.query(
            """
            SELECT a.feedID,
                   sum(CASE WHEN st.articleID IS NULL OR COALESCE(st.read, 0) = 0
                            THEN 1 ELSE 0 END) AS unread_total,
                   sum(CASE WHEN a.datePublished IS NOT NULL
                             AND a.datePublished >= ? AND a.datePublished <= ?
                             AND (st.articleID IS NULL OR COALESCE(st.read, 0) = 0)
                            THEN 1 ELSE 0 END) AS unread_in_window,
                   max(CASE WHEN a.datePublished IS NOT NULL
                             AND a.datePublished >= ? AND a.datePublished <= ?
                            THEN a.datePublished END) AS latest_published
            FROM articles AS a
            LEFT JOIN statuses AS st ON st.articleID = a.articleID
            WHERE a.feedID IS NOT NULL AND a.feedID <> ''
            GROUP BY a.feedID
            """,
            binds: [.real(since), .real(until), .real(since), .real(until)]
        )

        var aggregates: [String: FeedAggregate] = [:]
        for row in rows {
            guard row.count >= 4, let feedID = row[0].stringValue else { continue }
            aggregates[feedID] = FeedAggregate(
                unreadTotal: row[1].intValue ?? 0,
                unreadInWindow: row[2].intValue ?? 0,
                latestPublished: row[3].doubleValue
            )
        }
        return aggregates
    }

    private static func loadDetails(
        from database: ReadOnlyDatabase, since: Double, until: Double
    ) throws -> [String: [UnreadDigestArticle]] {
        let rows = try database.query(
            """
            SELECT articleID, feedID, datePublished, title
            FROM (
                SELECT a.articleID AS articleID,
                       a.feedID AS feedID,
                       a.datePublished AS datePublished,
                       f.title AS title,
                       row_number() OVER (
                           PARTITION BY a.feedID
                           ORDER BY (a.datePublished IS NULL) ASC,
                                    a.datePublished DESC,
                                    a.articleID DESC
                       ) AS rank
                FROM articles AS a
                LEFT JOIN search AS f ON f.rowid = a.searchRowID
                LEFT JOIN statuses AS st ON st.articleID = a.articleID
                WHERE a.datePublished IS NOT NULL
                  AND a.datePublished >= ? AND a.datePublished <= ?
                  AND a.feedID IS NOT NULL AND a.feedID <> ''
                  AND (st.articleID IS NULL OR COALESCE(st.read, 0) = 0)
            )
            WHERE rank <= ?
            ORDER BY feedID ASC, rank ASC
            """,
            binds: [.real(since), .real(until), .integer(Int64(maxArticlesPerFeed))]
        )

        var details: [String: [UnreadDigestArticle]] = [:]
        for row in rows {
            guard row.count >= 4,
                let articleID = row[0].stringValue,
                let feedID = row[1].stringValue
            else {
                continue
            }
            details[feedID, default: []].append(
                UnreadDigestArticle(
                    articleID: articleID,
                    title: normalizeOptional(row[3].stringValue),
                    publishedAt: row[2].doubleValue.map(DateFormats.iso8601(epochSeconds:))
                )
            )
        }
        return details
    }
}
