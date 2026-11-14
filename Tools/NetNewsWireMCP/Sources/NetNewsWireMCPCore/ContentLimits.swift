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

/// Drops articles from the tail until the compact JSON payload fits the byte
/// limit. `total_matched` is never affected; `returned` tracks the tail drops.
public func encodeListArticlesBounded(
    _ response: inout ListArticlesResponse,
    limit: Int = ContentLimits.listArticlesBytes
) throws -> String {
    while true {
        let data = try CompactJSON.encode(response)
        if data.count <= limit {
            guard let string = String(data: data, encoding: .utf8) else {
                throw ToolError("无法把响应编码为 UTF-8 JSON")
            }
            return string
        }
        guard !response.articles.isEmpty else {
            throw ToolError("list_articles 响应超过 \(limit) 字节上限，且无法再丢弃文章")
        }
        response.articles.removeLast()
        response.returned = response.articles.count
        response.omitted += 1
        response.truncated = true
    }
}

/// Shrinks `content` on Character boundaries until the whole response fits.
/// Any shrink sets `content_truncated`; the metadata alone exceeding the limit
/// is a tool error.
public func encodeGetArticleBounded(
    _ response: inout GetArticleResponse,
    limit: Int = ContentLimits.getArticleBytes
) throws -> String {
    var data = try CompactJSON.encode(response)
    if data.count <= limit {
        return try utf8String(data)
    }

    let originalContent = response.content
    var low = 0
    var high = originalContent.count - 1
    var best: Int?

    while low <= high {
        let middle = (low + high) / 2
        var candidate = response
        candidate.content = String(originalContent.prefix(middle))
        candidate.contentChars = candidate.content.count
        candidate.contentBytes = candidate.content.utf8.count
        candidate.contentTruncated = true
        let candidateData = try CompactJSON.encode(candidate)
        if candidateData.count <= limit {
            best = middle
            low = middle + 1
        } else {
            high = middle - 1
        }
    }

    guard let best else {
        throw ToolError("响应过大：get_article 响应超过 \(limit) 字节上限，正文已为空仍超限")
    }

    response.content = String(originalContent.prefix(best))
    response.contentChars = response.content.count
    response.contentBytes = response.content.utf8.count
    response.contentTruncated = true
    data = try CompactJSON.encode(response)
    guard data.count <= limit else {
        throw ToolError("响应过大：get_article 响应超过 \(limit) 字节上限")
    }
    return try utf8String(data)
}

private func utf8String(_ data: Data) throws -> String {
    guard let string = String(data: data, encoding: .utf8) else {
        throw ToolError("无法把响应编码为 UTF-8 JSON")
    }
    return string
}
