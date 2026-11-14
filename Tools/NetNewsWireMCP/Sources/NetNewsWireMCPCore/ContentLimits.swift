import Foundation

public enum ContentLimits {
    public static let listFeedsBytes = 64 * 1024
    public static let listArticlesBytes = 48 * 1024
    public static let searchArticlesBytes = 32 * 1024
    public static let getArticleBytes = 96 * 1024

    public static let excerptCharacters = 160
    public static let snippetRadius = 80
    public static let snippetMaximumCharacters = 400
}

public enum CompactJSON {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public static func string<T: Encodable>(_ value: T) throws -> String {
        let data = try encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw ToolError("无法把响应编码为 UTF-8 JSON")
        }
        return string
    }
}

/// Drops feeds from the tail until the compact JSON payload fits the byte
/// limit. Totals are never affected.
public func encodeListFeedsBounded(
    _ response: inout ListFeedsResponse,
    limit: Int = ContentLimits.listFeedsBytes
) throws -> String {
    while true {
        let data = try CompactJSON.encode(response)
        if data.count <= limit {
            guard let string = String(data: data, encoding: .utf8) else {
                throw ToolError("无法把响应编码为 UTF-8 JSON")
            }
            return string
        }
        guard !response.feeds.isEmpty else {
            throw ToolError("list_feeds 响应超过 \(limit) 字节上限，且无法再丢弃 feed")
        }
        response.feeds.removeLast()
        response.omitted += 1
        response.truncated = true
    }
}
