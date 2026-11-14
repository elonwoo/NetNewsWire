import CryptoKit
import Foundation
import XCTest

@testable import NetNewsWireMCPCore

final class ReadOnlyTests: XCTestCase {
    private func sha256(_ url: URL) throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: url))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func mtime(_ url: URL) throws -> Date {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.modificationDate] as? Date)
    }

    func testTwoHundredListFeedsCallsDoNotChangeFiles() throws {
        let root = try TestRoot()
        let context = try root.createStandardServerContext()

        let files = [root.databaseURL, root.feedSettingsURL, root.opmlURL]
        let hashesBefore = try files.map(sha256)
        let mtimesBefore = try files.map(mtime)

        for _ in 0..<200 {
            _ = try ListFeedsTool.run(context: context)
        }

        XCTAssertEqual(try files.map(sha256), hashesBefore)
        XCTAssertEqual(try files.map(mtime), mtimesBefore)
    }

    func testServerContextNeverWritesToTheFixture() throws {
        let root = try TestRoot()
        let context = try root.createStandardServerContext()
        let before = try sha256(root.databaseURL)
        _ = try ListFeedsTool.run(context: context)
        _ = try ListFeedsTool.run(context: context)
        XCTAssertEqual(try sha256(root.databaseURL), before)
    }
}
