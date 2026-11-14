import Foundation
import MCP

public struct ServerContext: Sendable {
    public let selectedPath: String
    public let candidatePaths: [String]
    public let isOverride: Bool
    public let unsupportedAccounts: [String]
    public let diagnostics: [String]
    public let opml: ParsedOPML

    public var databasePath: String { DataLocator.databasePath(root: selectedPath) }
    public var feedSettingsPath: String { DataLocator.feedSettingsPath(root: selectedPath) }
    public var subscriptionsPath: String { DataLocator.subscriptionsPath(root: selectedPath) }

    public init(
        selectedPath: String,
        candidatePaths: [String],
        isOverride: Bool,
        unsupportedAccounts: [String],
        diagnostics: [String],
        opml: ParsedOPML
    ) {
        self.selectedPath = selectedPath
        self.candidatePaths = candidatePaths
        self.isOverride = isOverride
        self.unsupportedAccounts = unsupportedAccounts
        self.diagnostics = diagnostics
        self.opml = opml
    }
}

/// Startup validation. The order of checks implements the exit-code priority
/// from the contract: 4 (data root/account/files) before 5 (database) before
/// 3 (schema) before 6 (OPML).
public enum Startup {
    public static func prepare(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String? = nil
    ) throws -> ServerContext {
        let selection = try DataLocator.locate(environment: environment, homeDirectory: homeDirectory)

        var diagnostics: [String] = []
        diagnostics.append("data_root=\(selection.selectedPath)")
        for candidate in selection.candidates {
            let mtime = candidate.dbMtime.map(DateFormats.iso8601) ?? "null"
            diagnostics.append(
                "candidate=\(candidate.path) exists=\(candidate.exists) db_mtime=\(mtime) selected=\(candidate.selected)"
            )
        }
        diagnostics.append("ambiguous_data_roots=\(selection.ambiguous)")
        if selection.isOverride {
            diagnostics.append("data_root_override=true")
        }

        let gate = try AccountGate.inspect(root: selection.selectedPath)
        for name in gate.unsupportedAccounts {
            diagnostics.append("warning=暂不支持账户：\(name)")
        }

        let databasePath = DataLocator.databasePath(root: selection.selectedPath)
        let feedSettingsPath = DataLocator.feedSettingsPath(root: selection.selectedPath)
        let subscriptionsPath = DataLocator.subscriptionsPath(root: selection.selectedPath)

        let requiredFiles = [
            (DataRootConstants.databaseFileName, databasePath),
            (DataRootConstants.feedSettingsFileName, feedSettingsPath),
            (DataRootConstants.subscriptionsFileName, subscriptionsPath),
        ]
        for (label, path) in requiredFiles {
            guard DataLocator.isRegularFile(path) else {
                throw StartupError(code: 4, message: "缺少必需文件 \(label)：\(path)")
            }
        }

        let database: ReadOnlyDatabase
        do {
            database = try ReadOnlyDatabase(path: databasePath)
        } catch let error as DatabaseError {
            throw StartupError(code: 5, message: error.description)
        } catch {
            throw StartupError(code: 5, message: "打开 \(databasePath) 失败：\(error)")
        }

        let feedSettings: ReadOnlyDatabase
        do {
            feedSettings = try ReadOnlyDatabase(path: feedSettingsPath)
        } catch let error as DatabaseError {
            throw StartupError(code: 5, message: error.description)
        } catch {
            throw StartupError(code: 5, message: "打开 \(feedSettingsPath) 失败：\(error)")
        }

        if SchemaValidator.hasJournal(for: databasePath) {
            diagnostics.append("hot_journal=\(databasePath)-journal 存在；只读读取成功，未删除 journal")
        }
        if SchemaValidator.hasJournal(for: feedSettingsPath) {
            diagnostics.append(
                "hot_journal=\(feedSettingsPath)-journal 存在；只读读取成功，未删除 journal")
        }

        do {
            try SchemaValidator.validateDatabase(database)
        } catch let error as DatabaseError {
            throw StartupError(code: 3, message: error.description)
        } catch {
            throw StartupError(code: 3, message: "schema 校验失败：\(error)")
        }

        do {
            try SchemaValidator.validateFeedSettings(feedSettings)
        } catch let error as DatabaseError {
            throw StartupError(code: 3, message: error.description)
        } catch {
            throw StartupError(code: 3, message: "schema 校验失败：\(error)")
        }

        let opml: ParsedOPML
        do {
            opml = try OPMLParser.parse(path: subscriptionsPath)
        } catch let error as OPMLError {
            throw StartupError(code: 6, message: error.description)
        } catch {
            throw StartupError(code: 6, message: "解析 OPML 失败 \(subscriptionsPath)：\(error)")
        }

        return ServerContext(
            selectedPath: selection.selectedPath,
            candidatePaths: selection.candidates.map(\.path),
            isOverride: selection.isOverride,
            unsupportedAccounts: gate.unsupportedAccounts,
            diagnostics: diagnostics,
            opml: opml
        )
    }
}

public enum ToolCatalog {
    public static let listFeeds = Tool(
        name: "list_feeds",
        description:
            "列出 NetNewsWire OnMyMac 账户的订阅源、文件夹、文章数与未读数。只读，不修改任何数据。",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([:]),
            "additionalProperties": .bool(false),
        ]),
        annotations: Tool.Annotations(
            readOnlyHint: true,
            destructiveHint: false,
            idempotentHint: true,
            openWorldHint: false
        )
    )

    public static let listArticles = Tool(
        name: "list_articles",
        description:
            "按发布时间倒序列出文章摘要，可按 feed_id 与未读状态过滤。只读，不返回正文。",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "feed_id": .object([
                    "type": .string("string"),
                    "description": .string("精确匹配的 feed_id；未知时返回错误"),
                ]),
                "unread_only": .object([
                    "type": .string("boolean"),
                    "description": .string("只返回未读文章，默认 false"),
                ]),
                "limit": .object([
                    "type": .string("integer"),
                    "minimum": .int(1),
                    "maximum": .int(100),
                    "default": .int(20),
                    "description": .string("返回条数上限，默认 20，最大 100"),
                ]),
            ]),
            "additionalProperties": .bool(false),
        ]),
        annotations: Tool.Annotations(
            readOnlyHint: true,
            destructiveHint: false,
            idempotentHint: true,
            openWorldHint: false
        )
    )

    public static let getArticle = Tool(
        name: "get_article",
        description:
            "按 article_id 或 url 读取单篇文章的元数据与纯文本正文，正文可按 Character 截断。只读。",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "article_id": .object([
                    "type": .string("string"),
                    "description": .string("文章 ID；与 url 二选一"),
                ]),
                "url": .object([
                    "type": .string("string"),
                    "description": .string("先匹配 articles.url，再匹配 articles.externalURL；与 article_id 二选一"),
                ]),
                "max_chars": .object([
                    "type": .string("integer"),
                    "minimum": .int(500),
                    "maximum": .int(32000),
                    "default": .int(20000),
                    "description": .string("正文最多返回的 Character 数，默认 20000，范围 500..32000"),
                ]),
            ]),
            "additionalProperties": .bool(false),
        ]),
        annotations: Tool.Annotations(
            readOnlyHint: true,
            destructiveHint: false,
            idempotentHint: true,
            openWorldHint: false
        )
    )

    public static let searchArticles = Tool(
        name: "search_articles",
        description:
            "按关键词检索文章：ASCII 词走全文索引，中文等 CJK 词走子串匹配，混合查询取交集。只读。",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object([
                    "type": .string("string"),
                    "description": .string("检索词；trim 后 1..200 字符"),
                ]),
                "limit": .object([
                    "type": .string("integer"),
                    "minimum": .int(1),
                    "maximum": .int(50),
                    "default": .int(20),
                    "description": .string("返回条数上限，默认 20，最大 50"),
                ]),
            ]),
            "required": .array([.string("query")]),
            "additionalProperties": .bool(false),
        ]),
        annotations: Tool.Annotations(
            readOnlyHint: true,
            destructiveHint: false,
            idempotentHint: true,
            openWorldHint: false
        )
    )

    public static let unreadDigest = Tool(
        name: "unread_digest",
        description:
            "汇总最近 N 天内各 feed 的未读文章，按 feed 列出计数与最多 3 条明细。只读。",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "days": .object([
                    "type": .string("integer"),
                    "minimum": .int(1),
                    "maximum": .int(90),
                    "default": .int(1),
                    "description": .string("窗口天数，默认 1，最大 90"),
                ])
            ]),
            "additionalProperties": .bool(false),
        ]),
        annotations: Tool.Annotations(
            readOnlyHint: true,
            destructiveHint: false,
            idempotentHint: true,
            openWorldHint: false
        )
    )

    public static var serverTools: [Tool] {
        [listFeeds, listArticles, getArticle, searchArticles, unreadDigest]
    }
}

enum ToolArgument {
    static func rejectUnknown(
        _ arguments: [String: Value], allowed: Set<String>, tool: String
    ) throws {
        let unknown = Set(arguments.keys).subtracting(allowed)
        guard unknown.isEmpty else {
            throw ToolError(
                "\(tool) 不接受参数：\(unknown.sorted().joined(separator: ", "))")
        }
    }

    static func string(_ arguments: [String: Value], _ key: String) throws -> String? {
        guard let value = arguments[key], !value.isNull else { return nil }
        guard let string = value.stringValue else {
            throw ToolError("参数 \(key) 必须是字符串")
        }
        return string
    }

    static func bool(_ arguments: [String: Value], _ key: String) throws -> Bool? {
        guard let value = arguments[key], !value.isNull else { return nil }
        guard let bool = value.boolValue else {
            throw ToolError("参数 \(key) 必须是布尔值")
        }
        return bool
    }

    static func int(_ arguments: [String: Value], _ key: String) throws -> Int? {
        guard let value = arguments[key], !value.isNull else { return nil }
        guard let int = value.intValue else {
            throw ToolError("参数 \(key) 必须是整数")
        }
        return int
    }
}

enum ToolDatabase {
    /// One connection per tool call: `DB.sqlite3` read-only, `FeedSettings.db`
    /// attached to the same connection before any transaction starts.
    static func open(context: ServerContext) throws -> ReadOnlyDatabase {
        do {
            let database = try ReadOnlyDatabase(path: context.databasePath)
            try database.attachReadOnlyDatabase(at: context.feedSettingsPath)
            return database
        } catch let error as DatabaseError {
            throw ToolError(error.description)
        } catch {
            throw ToolError(
                "打开 \(context.databasePath) 或附加 \(context.feedSettingsPath) 失败：\(error)")
        }
    }
}

public enum ToolDispatcher {
    public static func call(
        name: String,
        arguments: [String: Value]?,
        context: ServerContext
    ) -> CallTool.Result {
        switch name {
        case ToolCatalog.listFeeds.name:
            if let arguments, !arguments.isEmpty {
                return failure("list_feeds 不接受参数，收到：\(arguments.keys.sorted().joined(separator: ", "))")
            }
            do {
                let json = try ListFeedsTool.run(context: context)
                return .init(content: [text(json)], isError: false)
            } catch let error as ToolError {
                return failure(error.message)
            } catch {
                return failure("list_feeds 失败：\(error)")
            }
        case ToolCatalog.listArticles.name:
            do {
                let json = try ListArticlesTool.run(arguments: arguments, context: context)
                return .init(content: [text(json)], isError: false)
            } catch let error as ToolError {
                return failure(error.message)
            } catch {
                return failure("list_articles 失败：\(error)")
            }
        case ToolCatalog.getArticle.name:
            do {
                let json = try GetArticleTool.run(arguments: arguments, context: context)
                return .init(content: [text(json)], isError: false)
            } catch let error as ToolError {
                return failure(error.message)
            } catch {
                return failure("get_article 失败：\(error)")
            }
        case ToolCatalog.searchArticles.name:
            do {
                let json = try SearchArticlesTool.run(arguments: arguments, context: context)
                return .init(content: [text(json)], isError: false)
            } catch let error as ToolError {
                return failure(error.message)
            } catch {
                return failure("search_articles 失败：\(error)")
            }
        case ToolCatalog.unreadDigest.name:
            do {
                let json = try UnreadDigestTool.run(arguments: arguments, context: context)
                return .init(content: [text(json)], isError: false)
            } catch let error as ToolError {
                return failure(error.message)
            } catch {
                return failure("unread_digest 失败：\(error)")
            }
        default:
            return failure("未知工具：\(name)")
        }
    }

    public static func text(_ string: String) -> Tool.Content {
        .text(text: string, annotations: nil, _meta: nil)
    }

    public static func failure(_ message: String) -> CallTool.Result {
        .init(content: [text(message)], isError: true)
    }
}
