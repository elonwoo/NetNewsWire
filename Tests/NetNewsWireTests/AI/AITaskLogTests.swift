//
//  AITaskLogTests.swift
//  NetNewsWireTests
//

import Foundation
import Testing

@testable import NetNewsWire

@Suite(.serialized)
final class AITaskLogTests {

	@Test func writesOneSortedJSONLineWithoutEscapingChinese() async throws {
		let directory = try makeTemporaryDirectory()
		defer {
			removeDirectory(directory)
		}
		let date = Date(timeIntervalSince1970: 1_700_000_000)
		let log = AITaskLog(directoryProvider: { directory }, clock: { date })

		let event = AITaskTerminalEvent(
			jobID: "job-1",
			kind: .rewrite,
			articleID: "article-1",
			title: "中文标题",
			url: "https://example.com/article",
			trigger: .manual,
			outcome: .stored,
			durationMilliseconds: 123,
			feedCharacters: 456,
			inputCharacters: 789,
			outputCharacters: 1000,
			blocks: 5,
			fullText: true,
			model: "test-model",
			attempts: 1
		)
		await log.recordTerminal(event)
		let sameShape = AITaskTerminalEvent(
			jobID: "job-2",
			kind: .rewrite,
			articleID: "article-1",
			title: "中文标题",
			url: "https://example.com/article",
			trigger: .manual,
			outcome: .stored,
			durationMilliseconds: 123,
			feedCharacters: 456,
			inputCharacters: 789,
			outputCharacters: 1000,
			blocks: 5,
			fullText: true,
			model: "test-model",
			attempts: 1
		)
		await log.recordTerminal(sameShape)

		let data = try Data(contentsOf: fileURL(in: directory, for: date))
		let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
		#expect(lines.count == 3)
		#expect(lines[2].isEmpty)

		let first = String(lines[0])
		let second = String(lines[1])
		#expect(first == second)
		#expect(first.contains("中文标题"))
		#expect(!first.contains("\\u4e2d"))
		#expect(first.hasPrefix("{\"article_id\":"))

		let object = try #require(try JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any])
		#expect(object["article_id"] as? String == "article-1")
		#expect(object["kind"] as? String == "rewrite")
		#expect(object["trigger"] as? String == "manual")
		#expect(object["outcome"] as? String == "stored")
		#expect(object["duration_ms"] as? Int == 123)
		#expect(object["feed_chars"] as? Int == 456)
		#expect(object["input_chars"] as? Int == 789)
		#expect(object["output_chars"] as? Int == 1000)
		#expect(object["blocks"] as? Int == 5)
		#expect(object["full_text"] as? Bool == true)
		#expect(object["model"] as? String == "test-model")
		#expect(object["attempts"] as? Int == 1)
		#expect(object["title"] as? String == "中文标题")

		let timestamp = try #require(object["ts"] as? String)
		#expect(timestamp.contains("."))
		#expect(timestamp.hasSuffix("Z"))
		let millisecondPart = timestamp.split(separator: ".").last?.dropLast()
		#expect(millisecondPart?.count == 3)
	}

	@Test func concurrentWritesDoNotOverwriteEachOther() async throws {
		let directory = try makeTemporaryDirectory()
		defer {
			removeDirectory(directory)
		}
		let date = Date(timeIntervalSince1970: 1_700_000_000)
		let log = AITaskLog(directoryProvider: { directory }, clock: { date })

		async let first: Void = log.recordTerminal(AITaskTerminalEvent(
			jobID: "concurrent-1",
			kind: .translate,
			articleID: "article-a",
			trigger: .auto,
			outcome: .stored
		))
		async let second: Void = log.recordTerminal(AITaskTerminalEvent(
			jobID: "concurrent-2",
			kind: .translate,
			articleID: "article-b",
			trigger: .auto,
			outcome: .stored
		))
		_ = await (first, second)

		let data = try Data(contentsOf: fileURL(in: directory, for: date))
		let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
		#expect(lines.count == 2)
		let articleIDs = Set(lines.compactMap { line -> String? in
			let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
			return object?["article_id"] as? String
		})
		#expect(articleIDs == ["article-a", "article-b"])
	}

	@Test func crossDayEventsLandInDifferentFiles() async throws {
		let directory = try makeTemporaryDirectory()
		defer {
			removeDirectory(directory)
		}
		let clock = LockedDate(Date(timeIntervalSince1970: 1_700_000_000))
		let log = AITaskLog(directoryProvider: { directory }, clock: { clock.value })

		await log.recordTerminal(AITaskTerminalEvent(
			jobID: "day-1",
			kind: .rewrite,
			articleID: "article-day-1",
			trigger: .auto,
			outcome: .stored
		))
		let nextDay = clock.value.addingTimeInterval(26 * 60 * 60)
		clock.set(nextDay)
		await log.recordTerminal(AITaskTerminalEvent(
			jobID: "day-2",
			kind: .rewrite,
			articleID: "article-day-2",
			trigger: .auto,
			outcome: .stored
		))

		let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
		#expect(contents.count == 2)
		let firstFile = try Data(contentsOf: fileURL(in: directory, for: Date(timeIntervalSince1970: 1_700_000_000)))
		let secondFile = try Data(contentsOf: fileURL(in: directory, for: nextDay))
		#expect(String(decoding: firstFile, as: UTF8.self).contains("article-day-1"))
		#expect(String(decoding: secondFile, as: UTF8.self).contains("article-day-2"))
	}

	@Test func removesFilesOlderThanRetentionButKeepsToday() async throws {
		let directory = try makeTemporaryDirectory()
		defer {
			removeDirectory(directory)
		}
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let today = Date(timeIntervalSince1970: 1_700_000_000)
		let expired = Calendar.current.date(byAdding: .day, value: -31, to: today) ?? today
		let expiredURL = fileURL(in: directory, for: expired)
		let todayURL = fileURL(in: directory, for: today)
		try Data("{}\n".utf8).write(to: expiredURL)
		try Data("{}\n".utf8).write(to: todayURL)

		let log = AITaskLog(directoryProvider: { directory }, clock: { today })
		await log.recordTerminal(AITaskTerminalEvent(
			jobID: "retention",
			kind: .rewrite,
			articleID: "article-retention",
			trigger: .auto,
			outcome: .stored
		))

		#expect(!FileManager.default.fileExists(atPath: expiredURL.path))
		#expect(FileManager.default.fileExists(atPath: todayURL.path))
	}

	@Test func failingWriterDoesNotThrowOrCrash() async {
		let directory = URL(fileURLWithPath: "/tmp/ai-task-log-failing-writer")
		let log = AITaskLog(
			directoryProvider: { directory },
			clock: { Date(timeIntervalSince1970: 1_700_000_000) },
			writer: { _, _ in
				throw TestLogError.writeFailed
			}
		)

		await log.recordTerminal(AITaskTerminalEvent(
			jobID: "failing-1",
			kind: .translateTitles,
			articleID: "article-failing",
			trigger: .manual,
			outcome: .failed,
			error: "失败"
		))
		await log.recordAttempt(AITaskAttemptEvent(
			kind: .translate,
			articleID: "article-failing",
			trigger: .manual,
			outcome: .skipped,
			reason: .autoWorkDisabled
		))
	}

	@Test func duplicateTerminalEventsForOneJobAreWrittenOnce() async throws {
		let directory = try makeTemporaryDirectory()
		defer {
			removeDirectory(directory)
		}
		let date = Date(timeIntervalSince1970: 1_700_000_000)
		let log = AITaskLog(directoryProvider: { directory }, clock: { date })
		let event = AITaskTerminalEvent(
			jobID: "duplicate",
			kind: .rewrite,
			articleID: "article-duplicate",
			trigger: .auto,
			outcome: .stored
		)
		await log.recordTerminal(event)
		await log.recordTerminal(event)

		let data = try Data(contentsOf: fileURL(in: directory, for: date))
		let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
		#expect(lines.count == 1)
	}
}

private extension AITaskLogTests {

	func makeTemporaryDirectory() throws -> URL {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("AITaskLogTests-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		return url
	}

	func removeDirectory(_ url: URL) {
		try? FileManager.default.removeItem(at: url)
	}

	func fileURL(in directory: URL, for date: Date) -> URL {
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.timeZone = .current
		formatter.dateFormat = "yyyy-MM-dd"
		return directory.appendingPathComponent("ai-tasks-\(formatter.string(from: date)).jsonl")
	}
}

private enum TestLogError: Error {
	case writeFailed
}

private final class LockedDate: @unchecked Sendable {

	private let lock = NSLock()
	private var storedValue: Date

	init(_ value: Date) {
		self.storedValue = value
	}

	var value: Date {
		lock.lock()
		defer {
			lock.unlock()
		}
		return storedValue
	}

	func set(_ value: Date) {
		lock.lock()
		storedValue = value
		lock.unlock()
	}
}
