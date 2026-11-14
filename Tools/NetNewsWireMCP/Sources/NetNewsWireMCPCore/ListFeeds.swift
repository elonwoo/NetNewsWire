import Foundation

public enum ListFeedsTool {
    private struct SettingsRow {
        let feedURL: String
        let feedID: String?
        let editedName: String?
        let homePageURL: String?
    }

    private struct FeedStats {
        let articles: Int
        let unread: Int
        let latestPublished: Date?
    }

    private struct Aggregates {
        let articles: Int
        let unread: Int
        let starred: Int
        let perFeed: [String: FeedStats]
    }

    public static func run(context: ServerContext, now: Date = Date()) throws -> String {
        let snapshot = DataLocator.snapshot(
            candidatePaths: context.candidatePaths, selectedPath: context.selectedPath)
        guard let dataRootMtime = snapshot.selectedMtime else {
            throw ToolError(
                "无法读取数据根 \(context.selectedPath) 下 \(DataRootConstants.databaseFileName) 的 mtime")
        }

        let dataAge = max(0, Int(now.timeIntervalSince(dataRootMtime).rounded()))
        var warnings: [String] = []
        if dataAge > 86400 {
            warnings.append("数据超过 86400 秒未更新（data_age_seconds=\(dataAge)）")
        }
        if snapshot.ambiguous {
            warnings.append("两个数据根同时存在且 DB mtime 相差不足 300 秒，已选择 mtime 较新的一个")
        }
        for account in context.unsupportedAccounts {
            warnings.append("暂不支持账户：\(account)")
        }

        // One connection. FeedSettings.db is attached read-only to the same
        // connection, and both databases are read inside one DEFERRED
        // transaction.
        let database: ReadOnlyDatabase
        do {
            database = try ReadOnlyDatabase(path: context.databasePath)
            try database.attachReadOnlyDatabase(at: context.feedSettingsPath)
        } catch let error as DatabaseError {
            throw ToolError(error.description)
        } catch {
            throw ToolError("打开 \(context.databasePath) 或附加 \(context.feedSettingsPath) 失败：\(error)")
        }

        let settings: [SettingsRow]
        let aggregates: Aggregates
        do {
            (settings, aggregates) = try database.withReadTransaction {
                let settings = try loadSettings(from: database)
                let aggregates = try loadAggregates(from: database)
                return (settings, aggregates)
            }
        } catch let error as DatabaseError {
            throw ToolError(error.description)
        }

        var folderCounts: [String: (feeds: Int, unread: Int)] = [:]
        for folder in context.opml.folders {
            folderCounts[folder] = (0, 0)
        }

        var items: [ListFeedsItem] = []
        items.reserveCapacity(settings.count)
        for setting in settings {
            let displayID = normalizeOptional(setting.feedID) ?? setting.feedURL
            let opmlFeed =
                context.opml.feedsByURL[setting.feedURL]
                ?? normalizeOptional(setting.feedID).flatMap { context.opml.feedsByURL[$0] }
            let stats =
                aggregates.perFeed[setting.feedURL]
                ?? normalizeOptional(setting.feedID).flatMap { aggregates.perFeed[$0] }
                ?? FeedStats(articles: 0, unread: 0, latestPublished: nil)

            let title = normalizeOptional(setting.editedName) ?? opmlFeed?.name ?? displayID
            let homePageURL = normalizeOptional(setting.homePageURL) ?? opmlFeed?.htmlURL
            let folder = opmlFeed?.folder

            if let folder {
                let current = folderCounts[folder] ?? (0, 0)
                folderCounts[folder] = (current.feeds + 1, current.unread + stats.unread)
            }

            items.append(
                ListFeedsItem(
                    feedID: displayID,
                    title: title,
                    folder: folder,
                    homePageURL: homePageURL,
                    articleCount: stats.articles,
                    unreadCount: stats.unread,
                    latestPublishedAt: stats.latestPublished.map(DateFormats.iso8601)
                )
            )
        }

        items.sort { left, right in
            if left.unreadCount != right.unreadCount {
                return left.unreadCount > right.unreadCount
            }
            if left.title != right.title {
                return left.title < right.title
            }
            return left.feedID < right.feedID
        }

        let folders = folderCounts.map {
            ListFeedsFolder(name: $0.key, feedCount: $0.value.feeds, unreadCount: $0.value.unread)
        }
        .sorted { $0.name < $1.name }

        var response = ListFeedsResponse(
            dataRoot: context.selectedPath,
            dataRootMtime: DateFormats.iso8601(dataRootMtime),
            dataAgeSeconds: dataAge,
            ambiguousDataRoots: snapshot.ambiguous,
            dataRootCandidates: snapshot.candidates.map { candidate in
                DataRootCandidateInfo(
                    path: candidate.path,
                    exists: candidate.exists,
                    dbMtime: candidate.dbMtime.map(DateFormats.iso8601),
                    selected: candidate.selected
                )
            },
            warnings: warnings,
            account: DataRootConstants.accountName,
            unsupportedAccounts: context.unsupportedAccounts,
            generatedAt: DateFormats.iso8601(now),
            totals: ListFeedsTotals(
                feeds: settings.count,
                folders: context.opml.folders.count,
                articles: aggregates.articles,
                unread: aggregates.unread,
                starred: aggregates.starred
            ),
            folders: folders,
            feeds: items,
            truncated: false,
            omitted: 0
        )

        return try encodeListFeedsBounded(&response)
    }

    private static func loadSettings(from database: ReadOnlyDatabase) throws -> [SettingsRow] {
        let rows = try database.query(
            "SELECT feedURL, feedID, editedName, homePageURL FROM fs.feedSettings")
        return rows.compactMap { row in
            guard row.count >= 4, let feedURL = normalizeOptional(row[0].stringValue) else {
                return nil
            }
            return SettingsRow(
                feedURL: feedURL,
                feedID: row[1].stringValue,
                editedName: row[2].stringValue,
                homePageURL: row[3].stringValue
            )
        }
    }

    private static func loadAggregates(from database: ReadOnlyDatabase) throws -> Aggregates {
        let articles = try database.scalarInt("SELECT count(*) FROM articles") ?? 0
        let unread =
            try database.scalarInt(
                """
                SELECT count(*)
                FROM articles AS a
                LEFT JOIN statuses AS s ON s.articleID = a.articleID
                WHERE s.articleID IS NULL OR COALESCE(s.read, 0) = 0
                """
            ) ?? 0
        let starred =
            try database.scalarInt(
                "SELECT count(*) FROM statuses WHERE COALESCE(starred, 0) <> 0") ?? 0

        let rows = try database.query(
            """
            SELECT a.feedID,
                   count(*),
                   sum(CASE WHEN s.articleID IS NULL OR COALESCE(s.read, 0) = 0 THEN 1 ELSE 0 END),
                   max(CASE WHEN a.datePublished IS NOT NULL THEN a.datePublished END)
            FROM articles AS a
            LEFT JOIN statuses AS s ON s.articleID = a.articleID
            GROUP BY a.feedID
            """
        )

        var perFeed: [String: FeedStats] = [:]
        for row in rows {
            guard row.count >= 4, let feedID = row[0].stringValue else { continue }
            let latest = row[3].doubleValue.map { Date(timeIntervalSince1970: $0) }
            perFeed[feedID] = FeedStats(
                articles: row[1].intValue ?? 0,
                unread: row[2].intValue ?? 0,
                latestPublished: latest
            )
        }
        return Aggregates(articles: articles, unread: unread, starred: starred, perFeed: perFeed)
    }
}
