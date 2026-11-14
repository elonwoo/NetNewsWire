import Foundation

public struct OPMLFeed: Sendable, Equatable {
    public let xmlURL: String
    public let name: String?
    public let htmlURL: String?
    public let folder: String?

    public init(xmlURL: String, name: String?, htmlURL: String?, folder: String?) {
        self.xmlURL = xmlURL
        self.name = name
        self.htmlURL = htmlURL
        self.folder = folder
    }
}

public struct ParsedOPML: Sendable, Equatable {
    public let feedsByURL: [String: OPMLFeed]
    public let folders: [String]

    public init(feedsByURL: [String: OPMLFeed], folders: [String]) {
        self.feedsByURL = feedsByURL
        self.folders = folders
    }

    public static let empty = ParsedOPML(feedsByURL: [:], folders: [])
}

public enum OPMLError: Error, Sendable, CustomStringConvertible, Equatable {
    case unreadable(path: String, detail: String)
    case empty(path: String)
    case invalidXML(path: String, line: Int, column: Int, detail: String)
    case missingBody(path: String)

    public var description: String {
        switch self {
        case .unreadable(let path, let detail):
            return "无法读取 OPML \(path)：\(detail)"
        case .empty(let path):
            return "OPML 文件为 0 字节：\(path)"
        case .invalidXML(let path, let line, let column, let detail):
            return "OPML XML 非法 \(path)（第 \(line) 行第 \(column) 列）：\(detail)"
        case .missingBody(let path):
            return "OPML 缺少 <body> 元素：\(path)"
        }
    }
}

public enum OPMLParser {
    public static func parse(path: String) throws -> ParsedOPML {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw OPMLError.unreadable(path: path, detail: error.localizedDescription)
        }
        guard !data.isEmpty else {
            throw OPMLError.empty(path: path)
        }

        let parser = XMLParser(data: data)
        let delegate = OPMLDelegate()
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else {
            throw OPMLError.invalidXML(
                path: path,
                line: parser.lineNumber,
                column: parser.columnNumber,
                detail: parser.parserError?.localizedDescription ?? "XML 解析失败"
            )
        }
        guard delegate.sawBody else {
            throw OPMLError.missingBody(path: path)
        }

        var folders: [String] = []
        var seenFolders = Set<String>()
        for folder in delegate.folderOrder where seenFolders.insert(folder).inserted {
            folders.append(folder)
        }
        return ParsedOPML(feedsByURL: delegate.feeds, folders: folders)
    }
}

private final class OPMLDelegate: NSObject, XMLParserDelegate {
    var sawBody = false
    var feeds: [String: OPMLFeed] = [:]
    var folderOrder: [String] = []

    /// One entry per open `<outline>`; the value is the folder this outline
    /// creates, if any.
    private var outlineFolders: [String?] = []

    private var currentFolder: String? {
        outlineFolders.compactMap { $0 }.last
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "body" {
            sawBody = true
            return
        }
        guard elementName == "outline" else { return }

        let text = normalizeOptional(attributeDict["text"])
        let title = normalizeOptional(attributeDict["title"])
        let name = text ?? title
        let xmlURL = normalizeOptional(attributeDict["xmlUrl"])
        let type = normalizeOptional(attributeDict["type"])?.lowercased()

        let isFeed = xmlURL != nil || type == "rss" || type == "atom"
        if isFeed {
            if let xmlURL {
                feeds[xmlURL] = OPMLFeed(
                    xmlURL: xmlURL,
                    name: name,
                    htmlURL: normalizeOptional(attributeDict["htmlUrl"]),
                    folder: currentFolder
                )
            }
            outlineFolders.append(nil)
        } else {
            if let name {
                folderOrder.append(name)
            }
            outlineFolders.append(name)
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "outline", !outlineFolders.isEmpty {
            outlineFolders.removeLast()
        }
    }
}
