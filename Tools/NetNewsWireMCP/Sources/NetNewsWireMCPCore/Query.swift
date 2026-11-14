import Foundation
import MCP

/// Single-statement validation for `query`.
///
/// The check is intentionally shallow: it only proves there is exactly one
/// statement and that the first keyword is `SELECT` or `WITH`. Whether a
/// `WITH` body is writable is *not* decided statically; the read-only
/// connection is the final line of defence.
enum SQLStatementValidator {
    enum ValidationFailure: Error, Equatable {
        case multipleStatements
        case notSelect
    }

    static func singleStatement(from sql: String) throws -> String {
        let characters = Array(sql)
        let count = characters.count

        var index = 0
        skipWhitespaceAndComments(characters, &index)

        let keywordStart = index
        while index < count, isKeywordScalar(characters[index]) {
            index += 1
        }
        let keyword = String(characters[keywordStart..<index]).lowercased()
        guard keyword == "select" || keyword == "with" else {
            throw ValidationFailure.notSelect
        }

        var statementEnd: Int?
        while index < count {
            let character = characters[index]
            switch character {
            case "'":
                skipQuoted(characters, &index, quote: "'")
            case "\"":
                skipQuoted(characters, &index, quote: "\"")
            case "`":
                skipQuoted(characters, &index, quote: "`")
            case "[":
                index += 1
                while index < count, characters[index] != "]" {
                    index += 1
                }
                if index < count { index += 1 }
            case "-" where index + 1 < count && characters[index + 1] == "-":
                index += 2
                while index < count, characters[index] != "\n" {
                    index += 1
                }
            case "/" where index + 1 < count && characters[index + 1] == "*":
                index += 2
                while index + 1 < count,
                    !(characters[index] == "*" && characters[index + 1] == "/")
                {
                    index += 1
                }
                index = min(index + 2, count)
            case ";":
                if statementEnd == nil {
                    statementEnd = index
                }
                index += 1
            default:
                index += 1
            }
        }

        if let statementEnd, hasContent(characters, after: statementEnd + 1) {
            throw ValidationFailure.multipleStatements
        }

        if let statementEnd {
            return String(characters[0..<statementEnd])
        }
        return sql
    }

    /// Skips whitespace, `--` comments and `/* */` comments at `index`.
    private static func skipWhitespaceAndComments(_ characters: [Character], _ index: inout Int) {
        let count = characters.count
        while index < count {
            let character = characters[index]
            if character.isWhitespace {
                index += 1
            } else if character == "-", index + 1 < count, characters[index + 1] == "-" {
                index += 2
                while index < count, characters[index] != "\n" {
                    index += 1
                }
            } else if character == "/", index + 1 < count, characters[index + 1] == "*" {
                index += 2
                while index + 1 < count,
                    !(characters[index] == "*" && characters[index + 1] == "/")
                {
                    index += 1
                }
                index = min(index + 2, count)
            } else {
                return
            }
        }
    }

    /// True when anything other than whitespace, comments or further semicolons
    /// follows `index`.
    private static func hasContent(_ characters: [Character], after index: Int) -> Bool {
        var cursor = index
        skipWhitespaceAndComments(characters, &cursor)
        while cursor < characters.count {
            if characters[cursor] == ";" {
                cursor += 1
                skipWhitespaceAndComments(characters, &cursor)
                continue
            }
            return true
        }
        return false
    }

    private static func skipQuoted(_ characters: [Character], _ index: inout Int, quote: Character) {
        let count = characters.count
        index += 1
        while index < count {
            if characters[index] == quote {
                if index + 1 < count, characters[index + 1] == quote {
                    index += 2
                    continue
                }
                index += 1
                return
            }
            index += 1
        }
    }

    private static func isKeywordScalar(_ character: Character) -> Bool {
        character.isLetter
    }
}

public enum QueryTool {
    public static let defaultLimit = 50
    public static let maximumLimit = 100
    public static let defaultBudgetMilliseconds = 3000
    public static let sqlEchoCharacters = 200

    public static func run(
        arguments: [String: Value]?,
        context: ServerContext,
        budgetMilliseconds: Int = defaultBudgetMilliseconds
    ) throws -> String {
        let arguments = arguments ?? [:]
        try ToolArgument.rejectUnknown(arguments, allowed: ["sql", "limit"], tool: "query")

        guard let sql = try ToolArgument.string(arguments, "sql") else {
            throw ToolError("query 需要 sql 参数")
        }
        let limit = try ToolArgument.int(arguments, "limit") ?? defaultLimit
        guard (1...maximumLimit).contains(limit) else {
            throw ToolError("limit 必须在 1..\(maximumLimit) 之间，收到 \(limit)")
        }

        let statement: String
        do {
            statement = try SQLStatementValidator.singleStatement(from: sql)
        } catch SQLStatementValidator.ValidationFailure.multipleStatements {
            throw ToolError(
                refusalMessage(
                    category: "multiple_statements", detail: "只允许单条语句", sql: sql))
        } catch SQLStatementValidator.ValidationFailure.notSelect {
            throw ToolError(
                refusalMessage(
                    category: "not_select", detail: "只允许 SELECT 或 WITH 开头的单条语句",
                    sql: sql))
        }

        let effectiveLimit = min(limit, maximumLimit)
        let budget = SQLiteProgressBudget(milliseconds: budgetMilliseconds)
        let database = try ToolDatabase.open(context: context)

        let started = DispatchTime.now().uptimeNanoseconds
        let result: ReadOnlyDatabase.CappedQueryResult
        do {
            result = try database.withReadTransaction {
                try database.withProgressBudget(budget) {
                    try database.queryCapped(statement, maximumRows: effectiveLimit + 1)
                }
            }
        } catch let failure as ReadOnlyDatabase.QueryFailure {
            if budget.didInterrupt {
                throw ToolError(
                    refusalMessage(
                        category: "timeout", detail: "查询超时（超过 \(budgetMilliseconds) ms）",
                        sql: sql))
            }
            let lowercased = failure.message.lowercased()
            let category: String
            if failure.phase == .prepare {
                category =
                    (lowercased.contains("readonly") || lowercased.contains("read-only")
                        || lowercased.contains("query_only"))
                    ? "execution_error" : "syntax_error"
            } else {
                category = "execution_error"
            }
            throw ToolError(
                refusalMessage(category: category, detail: failure.message, sql: sql))
        } catch let error as DatabaseError {
            throw ToolError(
                refusalMessage(category: "execution_error", detail: error.description, sql: sql))
        }
        let elapsedMs = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)

        let rowLimited = result.rows.count > effectiveLimit || result.hasMore
        let returnedRows = Array(result.rows.prefix(effectiveLimit))

        if let firstRow = returnedRows.first {
            let firstRowBytes = try CompactJSON.encode([firstRow.map(mapValue)]).count
            guard firstRowBytes <= ContentLimits.queryBytes else {
                throw ToolError(
                    "query 失败（类别：single_row_too_large）：第一行 JSON 为 \(firstRowBytes) 字节，"
                        + "超过 \(ContentLimits.queryBytes) 字节上限；请缩小列投影或加过滤")
            }
        }

        var rows = returnedRows.map { $0.map(mapValue) }
        var response = QueryResponse(
            columns: result.columns,
            rows: rows,
            rowCount: rows.count,
            truncated: rowLimited,
            truncatedReason: rowLimited ? "row_limit" : nil,
            elapsedMs: elapsedMs
        )

        while true {
            response.rows = rows
            response.rowCount = rows.count
            let byteDropped = rows.count < returnedRows.count
            let truncated = rowLimited || byteDropped
            response.truncated = truncated
            response.truncatedReason = byteDropped
                ? "byte_limit" : (rowLimited ? "row_limit" : nil)

            let data = try CompactJSON.encode(response)
            if data.count <= ContentLimits.queryBytes {
                guard let string = String(data: data, encoding: .utf8) else {
                    throw ToolError("无法把响应编码为 UTF-8 JSON")
                }
                return string
            }
            guard !rows.isEmpty else {
                throw ToolError(
                    "query 失败（类别：byte_limit）：响应超过 \(ContentLimits.queryBytes) 字节上限，"
                        + "且已无行可丢；请缩小列投影或加过滤")
            }
            rows.removeLast()
        }
    }

    private static func mapValue(_ value: SQLValue) -> QueryValue {
        switch value {
        case .null:
            return .null
        case .integer(let number):
            return .integer(number)
        case .real(let number):
            return .real(number)
        case .text(let string):
            return .text(string)
        case .blob(let data):
            var hex = ""
            hex.reserveCapacity(data.count * 2)
            for byte in data {
                hex += String(format: "%02x", byte)
            }
            return .blobHex(hex)
        }
    }

    private static func refusalMessage(category: String, detail: String?, sql: String) -> String {
        let prefix = String(sql.prefix(sqlEchoCharacters))
        var message = "query 失败（类别：\(category)）"
        if let detail, !detail.isEmpty {
            message += "：\(detail)"
        }
        message += "；SQL 前 \(prefix.count) 字符：\(prefix)"
        return message
    }
}
