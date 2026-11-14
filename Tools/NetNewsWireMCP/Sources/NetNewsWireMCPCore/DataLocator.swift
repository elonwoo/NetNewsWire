import Foundation

public enum DataRootConstants {
    public static let environmentKey = "NNW_MCP_DATA_ROOT"
    public static let accountName = "OnMyMac"
    public static let databaseFileName = "DB.sqlite3"
    public static let feedSettingsFileName = "FeedSettings.db"
    public static let subscriptionsFileName = "Subscriptions.opml"

    public static let activeRelativePath = "Library/Application Support/NetNewsWire"
    public static let legacyContainerRelativePath =
        "Library/Containers/com.ranchero.NetNewsWire-Evergreen/Data/Library/Application Support/NetNewsWire"

    public static let defaultCandidateRelativePaths = [
        activeRelativePath,
        legacyContainerRelativePath,
    ]
}

/// A candidate data root with the mtime of its `Accounts/OnMyMac/DB.sqlite3`.
public struct CandidateProbe: Sendable, Equatable {
    public let path: String
    public let exists: Bool
    public let dbMtime: Date?
    public let selected: Bool

    public init(path: String, exists: Bool, dbMtime: Date?, selected: Bool) {
        self.path = path
        self.exists = exists
        self.dbMtime = dbMtime
        self.selected = selected
    }
}

public struct RootSelection: Sendable, Equatable {
    public let candidates: [CandidateProbe]
    public let selectedPath: String
    public let ambiguous: Bool
    public let isOverride: Bool

    public init(candidates: [CandidateProbe], selectedPath: String, ambiguous: Bool, isOverride: Bool) {
        self.candidates = candidates
        self.selectedPath = selectedPath
        self.ambiguous = ambiguous
        self.isOverride = isOverride
    }

    public var selectedMtime: Date? {
        candidates.first { $0.selected }?.dbMtime
    }
}

/// Fresh view of the configured candidates, used by tool responses.
public struct RootSnapshot: Sendable, Equatable {
    public let candidates: [CandidateProbe]
    public let ambiguous: Bool
    public let selectedMtime: Date?

    public init(candidates: [CandidateProbe], ambiguous: Bool, selectedMtime: Date?) {
        self.candidates = candidates
        self.ambiguous = ambiguous
        self.selectedMtime = selectedMtime
    }
}

public enum DataLocator {
    public static func databasePath(root: String) -> String {
        path(root, components: ["Accounts", DataRootConstants.accountName, DataRootConstants.databaseFileName])
    }

    public static func feedSettingsPath(root: String) -> String {
        path(root, components: ["Accounts", DataRootConstants.accountName, DataRootConstants.feedSettingsFileName])
    }

    public static func subscriptionsPath(root: String) -> String {
        path(root, components: ["Accounts", DataRootConstants.accountName, DataRootConstants.subscriptionsFileName])
    }

    public static func path(_ root: String, components: [String]) -> String {
        var url = URL(fileURLWithPath: root)
        for component in components {
            url.appendPathComponent(component)
        }
        return url.standardizedFileURL.path
    }

    /// Locates the data root following the contract.
    ///
    /// `NNW_MCP_DATA_ROOT` is an override: when set, only that root is
    /// considered and a missing root is a hard exit-4 failure. Without the
    /// override, the two default candidates are compared by the mtime of
    /// `Accounts/OnMyMac/DB.sqlite3` (never the directory mtime).
    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String? = nil
    ) throws -> RootSelection {
        let home = homeDirectory ?? NSHomeDirectory()

        if let rawOverride = environment[DataRootConstants.environmentKey],
            !rawOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            let overridePath = (rawOverride as NSString).expandingTildeInPath
            let standardized = URL(fileURLWithPath: overridePath).standardizedFileURL.path
            let probe = probe(path: standardized, selected: true)
            guard probe.exists else {
                throw StartupError(
                    code: 4,
                    message:
                        "NNW_MCP_DATA_ROOT 指向的路径不存在或不是目录：\(standardized)；不会回退到默认数据根。"
                )
            }
            return RootSelection(
                candidates: [probe], selectedPath: standardized, ambiguous: false, isOverride: true)
        }

        let paths = DataRootConstants.defaultCandidateRelativePaths.map {
            URL(fileURLWithPath: home).appendingPathComponent($0).standardizedFileURL.path
        }
        let probes = paths.map { probe(path: $0, selected: false) }
        let existing = probes.filter(\.exists)
        guard !existing.isEmpty else {
            let list = paths.map { "  \($0)（不存在）" }.joined(separator: "\n")
            throw StartupError(code: 4, message: "找不到 NetNewsWire 数据根。已尝试：\n\(list)")
        }

        var chosen = existing[0]
        for candidate in existing.dropFirst() {
            switch (candidate.dbMtime, chosen.dbMtime) {
            case let (candidateMtime?, chosenMtime?):
                if candidateMtime > chosenMtime { chosen = candidate }
            case (.some, .none):
                chosen = candidate
            default:
                break
            }
        }

        let marked = probes.map {
            CandidateProbe(
                path: $0.path, exists: $0.exists, dbMtime: $0.dbMtime, selected: $0.path == chosen.path)
        }
        let ambiguous = isAmbiguous(marked)
        return RootSelection(
            candidates: marked, selectedPath: chosen.path, ambiguous: ambiguous, isOverride: false)
    }

    /// Re-reads candidate mtimes for a tool response.
    public static func snapshot(candidatePaths: [String], selectedPath: String) -> RootSnapshot {
        let probes = candidatePaths.map {
            probe(path: $0, selected: $0 == selectedPath)
        }
        let selectedMtime = probes.first { $0.selected }?.dbMtime
        return RootSnapshot(
            candidates: probes, ambiguous: isAmbiguous(probes), selectedMtime: selectedMtime)
    }

    private static func isAmbiguous(_ probes: [CandidateProbe]) -> Bool {
        guard probes.count == 2, probes.allSatisfy(\.exists) else { return false }
        guard let first = probes[0].dbMtime, let second = probes[1].dbMtime else { return false }
        return abs(first.timeIntervalSince(second)) < 300
    }

    private static func probe(path: String, selected: Bool) -> CandidateProbe {
        let exists = isDirectory(path)
        let mtime = fileModificationDate(databasePath(root: path))
        return CandidateProbe(path: path, exists: exists, dbMtime: mtime, selected: selected)
    }

    public static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    public static func isRegularFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && !isDirectory.boolValue
    }

    public static func fileModificationDate(_ path: String) -> Date? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return nil
        }
        return attributes[.modificationDate] as? Date
    }

    public static func fileSize(_ path: String) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return nil
        }
        return (attributes[.size] as? NSNumber)?.int64Value
    }
}

public struct AccountGateResult: Sendable, Equatable {
    public let onMyMacPath: String
    public let unsupportedAccounts: [String]

    public init(onMyMacPath: String, unsupportedAccounts: [String]) {
        self.onMyMacPath = onMyMacPath
        self.unsupportedAccounts = unsupportedAccounts
    }
}

public enum AccountGate {
    /// Only accounts whose directory is named exactly `OnMyMac` may be read.
    /// Other account directories are reported by name and never opened.
    public static func inspect(root: String) throws -> AccountGateResult {
        let accountsPath = DataLocator.path(root, components: ["Accounts"])
        guard DataLocator.isDirectory(accountsPath) else {
            throw StartupError(code: 4, message: "数据根下缺少 Accounts 目录：\(accountsPath)")
        }

        let entries: [String]
        do {
            entries = try FileManager.default.contentsOfDirectory(atPath: accountsPath)
        } catch {
            throw StartupError(
                code: 4, message: "无法列出账户目录 \(accountsPath)：\(error.localizedDescription)")
        }

        let directories = entries.sorted().filter {
            DataLocator.isDirectory(DataLocator.path(accountsPath, components: [$0]))
        }
        guard directories.contains(DataRootConstants.accountName) else {
            let others = directories.filter { $0 != DataRootConstants.accountName }
            let message: String
            if others.isEmpty {
                message = "Accounts 下没有可读取的账户，当前只支持 OnMyMac；暂不支持其它账户。路径：\(accountsPath)"
            } else {
                message =
                    "暂不支持账户：\(others.joined(separator: "、"))；缺少必读的 OnMyMac 账户。路径：\(accountsPath)"
            }
            throw StartupError(code: 4, message: message)
        }

        let unsupported = directories.filter { $0 != DataRootConstants.accountName }
        let onMyMacPath = DataLocator.path(accountsPath, components: [DataRootConstants.accountName])
        return AccountGateResult(onMyMacPath: onMyMacPath, unsupportedAccounts: unsupported)
    }
}
