import Foundation
import SQLite3

private nonisolated(unsafe) let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum DatabaseError: Error, Sendable, CustomStringConvertible, Equatable {
    case zeroByte(path: String)
    case cannotOpen(path: String, detail: String)
    case readFailed(path: String, detail: String)
    case schemaInvalid(path: String, reason: String)

    public var description: String {
        switch self {
        case .zeroByte(let path):
            return "数据库文件为 0 字节：\(path)"
        case .cannotOpen(let path, let detail):
            return "无法打开数据库 \(path)：\(detail)"
        case .readFailed(let path, let detail):
            return "读取数据库失败 \(path)：\(detail)"
        case .schemaInvalid(let path, let reason):
            return "数据库 schema 不符合要求 \(path)：\(reason)"
        }
    }
}

public enum SQLValue: Sendable, Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob

    public var intValue: Int? {
        switch self {
        case .integer(let value): return Int(value)
        case .real(let value): return Int(value)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .integer(let value): return Double(value)
        case .real(let value): return value
        default: return nil
        }
    }

    public var stringValue: String? {
        if case .text(let value) = self { return value }
        return nil
    }
}

public enum SQLBind: Sendable, Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
}

/// A wall-clock budget enforced by SQLite's progress handler. The handler is
/// invoked every 1000 VM instructions; once the deadline passes it reports
/// `interrupted` and asks SQLite to abort the current statement.
public final class SQLiteProgressBudget: @unchecked Sendable {
    private let deadline: DispatchTime
    private let lock = NSLock()
    private var interrupted = false

    public init(milliseconds: Int) {
        deadline = .now() + .milliseconds(milliseconds)
    }

    var isExpired: Bool {
        DispatchTime.now() >= deadline
    }

    func markInterrupted() {
        lock.lock()
        interrupted = true
        lock.unlock()
    }

    /// Whether the handler actually aborted a statement (as opposed to the
    /// deadline passing between statements).
    public var didInterrupt: Bool {
        lock.lock()
        defer { lock.unlock() }
        return interrupted
    }
}

final class ConnectionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    func reset() {
        lock.lock()
        value = 0
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// A read-only SQLite connection.
///
/// The file is opened by plain path with `SQLITE_OPEN_READONLY`; URIs are
/// deliberately not enabled. `PRAGMA query_only` and a 2000 ms busy timeout are
/// applied, and `PRAGMA schema_version` forces one real read before the
/// connection is used.
public final class ReadOnlyDatabase {
    /// Used by tests to assert that one tool call opens exactly one connection.
    static let connectionCounter = ConnectionCounter()

    public let path: String
    private var handle: OpaquePointer?

    public init(path: String) throws {
        self.path = path

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            throw DatabaseError.cannotOpen(path: path, detail: "文件不存在或无法读取属性")
        }
        guard (attributes[.type] as? FileAttributeType) == .typeRegular else {
            throw DatabaseError.cannotOpen(path: path, detail: "不是普通文件")
        }
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard fileSize > 0 else {
            throw DatabaseError.zeroByte(path: path)
        }

        var database: OpaquePointer?
        let result = sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil)
        guard result == SQLITE_OK, let database else {
            let detail = database.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2 返回 \(result)"
            if let database { sqlite3_close(database) }
            throw DatabaseError.cannotOpen(path: path, detail: detail)
        }
        self.handle = database
        Self.connectionCounter.increment()
        sqlite3_busy_timeout(database, 2000)

        do {
            try execute("PRAGMA query_only = ON")
            _ = try query("PRAGMA schema_version")
        } catch {
            sqlite3_close(database)
            self.handle = nil
            throw error
        }
    }

    deinit {
        if let handle {
            sqlite3_close(handle)
        }
    }

    public func execute(_ sql: String) throws {
        guard let handle else {
            throw DatabaseError.readFailed(path: path, detail: "连接已关闭")
        }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let detail =
                errorMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(handle))
            if let errorMessage { sqlite3_free(errorMessage) }
            throw DatabaseError.readFailed(path: path, detail: "\(sql)：\(detail)")
        }
        if let errorMessage { sqlite3_free(errorMessage) }
    }

    public func query(_ sql: String, binds: [SQLBind] = []) throws -> [[SQLValue]] {
        guard let handle else {
            throw DatabaseError.readFailed(path: path, detail: "连接已关闭")
        }

        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else {
            throw DatabaseError.readFailed(
                path: path, detail: "\(sql)：\(String(cString: sqlite3_errmsg(handle)))")
        }
        defer { sqlite3_finalize(statement) }

        for (offset, bind) in binds.enumerated() {
            let index = Int32(offset + 1)
            let bindResult: Int32
            switch bind {
            case .null:
                bindResult = sqlite3_bind_null(statement, index)
            case .integer(let value):
                bindResult = sqlite3_bind_int64(statement, index, value)
            case .real(let value):
                bindResult = sqlite3_bind_double(statement, index, value)
            case .text(let value):
                bindResult = sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
            }
            guard bindResult == SQLITE_OK else {
                throw DatabaseError.readFailed(
                    path: path,
                    detail: "绑定第 \(offset + 1) 个参数失败：\(String(cString: sqlite3_errmsg(handle)))")
            }
        }

        var rows: [[SQLValue]] = []
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE { break }
            guard stepResult == SQLITE_ROW else {
                throw DatabaseError.readFailed(
                    path: path,
                    detail: "\(sql)：\(String(cString: sqlite3_errmsg(handle)))")
            }

            let columnCount = sqlite3_column_count(statement)
            var row: [SQLValue] = []
            row.reserveCapacity(Int(columnCount))
            for column in 0..<columnCount {
                row.append(readColumn(statement: statement, index: column))
            }
            rows.append(row)
        }
        return rows
    }

    public func scalarInt(_ sql: String, binds: [SQLBind] = []) throws -> Int? {
        try query(sql, binds: binds).first?.first?.intValue
    }

    /// Attaches another database to this connection. The attached database
    /// inherits `SQLITE_OPEN_READONLY` and `query_only` from the main
    /// connection, so it cannot be written either.
    public func attachReadOnlyDatabase(at path: String, as schema: String = "fs") throws {
        let escapedPath = path.replacingOccurrences(of: "'", with: "''")
        let escapedSchema = schema.replacingOccurrences(of: "\"", with: "\"\"")
        try execute("ATTACH '\(escapedPath)' AS \"\(escapedSchema)\"")
    }

    /// Runs `body` inside one `BEGIN DEFERRED` read transaction. A read
    /// transaction never opens a write transaction, and it is closed before
    /// the call returns.
    public func withReadTransaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN DEFERRED")
        do {
            let result = try body()
            try execute("ROLLBACK")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Installs a progress handler for the duration of `body`. Statements that
    /// step past the budget are aborted with `SQLITE_INTERRUPT`, which surfaces
    /// as a `readFailed` error; callers distinguish the timeout through
    /// `budget.didInterrupt`. The handler is always removed afterwards.
    public func withProgressBudget<T>(
        _ budget: SQLiteProgressBudget, _ body: () throws -> T
    ) rethrows -> T {
        guard let handle else { return try body() }
        let callback: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { context in
            guard let context else { return 0 }
            let budget = Unmanaged<SQLiteProgressBudget>.fromOpaque(context)
                .takeUnretainedValue()
            guard budget.isExpired else { return 0 }
            budget.markInterrupted()
            return 1
        }
        sqlite3_progress_handler(
            handle, 1000, callback, Unmanaged.passUnretained(budget).toOpaque())
        defer { sqlite3_progress_handler(handle, 0, nil, nil) }
        return try body()
    }

    private func readColumn(statement: OpaquePointer, index: Int32) -> SQLValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            guard let pointer = sqlite3_column_text(statement, index) else { return .null }
            let count = Int(sqlite3_column_bytes(statement, index))
            let buffer = UnsafeBufferPointer(start: pointer, count: count)
            return .text(String(decoding: buffer, as: UTF8.self))
        case SQLITE_BLOB:
            return .blob
        default:
            return .null
        }
    }
}

/// Finds a table reference in trigger SQL by scanning identifiers, not by
/// substring. `searchRowID` is one identifier and does not match `search`;
/// comments and string literals are skipped.
enum SQLIdentifierScanner {
    static func containsIdentifier(_ target: String, in sql: String) -> Bool {
        let scalars = Array(sql.unicodeScalars)
        let target = target.lowercased()
        var index = 0

        while index < scalars.count {
            let scalar = scalars[index].value

            if scalar == 45, index + 1 < scalars.count, scalars[index + 1].value == 45 {
                index += 2
                while index < scalars.count, scalars[index].value != 10 {
                    index += 1
                }
                continue
            }

            if scalar == 47, index + 1 < scalars.count, scalars[index + 1].value == 42 {
                index += 2
                while index + 1 < scalars.count,
                    !(scalars[index].value == 42 && scalars[index + 1].value == 47)
                {
                    index += 1
                }
                index = min(index + 2, scalars.count)
                continue
            }

            if scalar == 39 {
                index += 1
                while index < scalars.count {
                    if scalars[index].value == 39 {
                        if index + 1 < scalars.count, scalars[index + 1].value == 39 {
                            index += 2
                            continue
                        }
                        index += 1
                        break
                    }
                    index += 1
                }
                continue
            }

            if scalar == 34 || scalar == 96 || scalar == 91 {
                let closing: UInt32 = scalar == 34 ? 34 : (scalar == 96 ? 96 : 93)
                index += 1
                var identifier = ""
                while index < scalars.count {
                    if scalars[index].value == closing {
                        if closing != 93, index + 1 < scalars.count,
                            scalars[index + 1].value == closing
                        {
                            identifier.unicodeScalars.append(scalars[index])
                            index += 2
                            continue
                        }
                        index += 1
                        break
                    }
                    identifier.unicodeScalars.append(scalars[index])
                    index += 1
                }
                if identifier.lowercased() == target {
                    return true
                }
                continue
            }

            if isIdentifierScalar(scalar) {
                var identifier = ""
                while index < scalars.count, isIdentifierScalar(scalars[index].value) {
                    identifier.unicodeScalars.append(scalars[index])
                    index += 1
                }
                if identifier.lowercased() == target {
                    return true
                }
                continue
            }

            index += 1
        }
        return false
    }

    private static func isIdentifierScalar(_ scalar: UInt32) -> Bool {
        switch scalar {
        case 48...57, 65...90, 97...122, 95, 36:
            return true
        default:
            return scalar >= 0x80
        }
    }
}

public enum SchemaValidator {
    private static let requiredArticleColumns = [
        "articleID", "feedID", "title", "url", "externalURL", "datePublished",
        "dateModified", "searchRowID", "contentText", "contentHTML", "authors",
    ]
    private static let requiredStatusColumns = ["articleID", "read", "starred", "dateArrived"]

    public static func validateDatabase(_ database: ReadOnlyDatabase) throws {
        try requireObject(named: "articles", type: "table", in: database)
        try requireObject(named: "statuses", type: "table", in: database)
        try requireObject(named: "search", type: "table", in: database)

        let articleColumns = try columns(ofTable: "articles", in: database)
        let missingArticleColumns = requiredArticleColumns.filter { !articleColumns.contains($0) }
        guard missingArticleColumns.isEmpty else {
            throw DatabaseError.schemaInvalid(
                path: database.path,
                reason: "articles 缺少列：\(missingArticleColumns.joined(separator: ", "))")
        }

        let statusColumns = try columns(ofTable: "statuses", in: database)
        let missingStatusColumns = requiredStatusColumns.filter { !statusColumns.contains($0) }
        guard missingStatusColumns.isEmpty else {
            throw DatabaseError.schemaInvalid(
                path: database.path,
                reason: "statuses 缺少列：\(missingStatusColumns.joined(separator: ", "))")
        }

        let searchDefinition =
            try database.query("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'search'")
            .first?.first?.stringValue ?? ""
        guard searchDefinition.lowercased().contains("using fts4") else {
            throw DatabaseError.schemaInvalid(
                path: database.path, reason: "search 不是 FTS4 虚拟表；定义：\(searchDefinition)")
        }

        let searchColumns = try columns(ofTable: "search", in: database)
        let missingSearchColumns = ["title", "body"].filter { !searchColumns.contains($0) }
        guard missingSearchColumns.isEmpty else {
            throw DatabaseError.schemaInvalid(
                path: database.path,
                reason: "search 缺少列：\(missingSearchColumns.joined(separator: ", "))")
        }

        let triggers =
            try database.query("SELECT sql FROM sqlite_master WHERE type = 'trigger' AND sql IS NOT NULL")
            .compactMap { $0.first?.stringValue }
        guard triggers.contains(where: { SQLIdentifierScanner.containsIdentifier("search", in: $0) })
        else {
            throw DatabaseError.schemaInvalid(
                path: database.path, reason: "没有任何 trigger 的 SQL 引用 search")
        }
    }

    public static func validateFeedSettings(_ database: ReadOnlyDatabase) throws {
        try requireObject(named: "feedSettings", type: "table", in: database)
    }

    public static func hasJournal(for databasePath: String) -> Bool {
        FileManager.default.fileExists(atPath: databasePath + "-journal")
    }

    private static func requireObject(named name: String, type: String, in database: ReadOnlyDatabase) throws {
        let count = try database.scalarInt(
            "SELECT count(*) FROM sqlite_master WHERE type = ? AND name = ?",
            binds: [.text(type), .text(name)])
        guard count == 1 else {
            throw DatabaseError.schemaInvalid(path: database.path, reason: "缺少必需的 \(type)：\(name)")
        }
    }

    private static func columns(ofTable table: String, in database: ReadOnlyDatabase) throws -> Set<String> {
        let quoted = "\"" + table.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        return Set(
            try database.query("PRAGMA table_info(\(quoted))")
                .compactMap { $0.count > 1 ? $0[1].stringValue : nil }
        )
    }
}
