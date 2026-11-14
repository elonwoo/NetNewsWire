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

    /// P0 registers only the implemented tool.
    public static var serverTools: [Tool] {
        [listFeeds]
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
