//
//  AITaskLog.swift
//  NetNewsWire
//

import AI
import Foundation
import os

enum AITaskLogKind: String, Codable, Sendable {
	case rewrite
	case translate
	case translateTitles = "translate_titles"
}

extension AIJobKind {

	var taskLogKind: AITaskLogKind {
		switch self {
		case .rewrite:
			return .rewrite
		case .bodyTranslation:
			return .translate
		case .titleTranslation:
			return .translateTitles
		}
	}
}

enum AITaskLogTrigger: String, Codable, Sendable {
	case auto
	case manual
	case catchUp = "catch_up"
	case unknown
}

enum AITaskLogOutcome: String, Codable, Sendable {
	case stored
	case cached
	case failed
	case skipped
}

enum AITaskLogReason: String, Codable, Sendable {
	case notConfigured = "not_configured"
	case articleMissing = "article_missing"
	case chineseArticle = "chinese_article"
	case feedTranslationDisabled = "feed_translation_disabled"
	case feedRewriteDisabled = "feed_rewrite_disabled"
	case emptyBody = "empty_body"
	case bodyTooShort = "body_too_short"
	case fullTextUnavailable = "full_text_unavailable"
	case qualityRejected = "quality_rejected"
	case autoWorkDisabled = "auto_work_disabled"
	case enqueueFailed = "enqueue_failed"
	case alreadyInFlight = "already_in_flight"
}

/// A terminal job outcome. `jobID` drives in-process idempotency and is never
/// written to the file.
struct AITaskTerminalEvent: Sendable {
	let jobID: String
	var ts: String
	let kind: AITaskLogKind
	let articleID: String
	var title: String?
	var url: String?
	let trigger: AITaskLogTrigger
	let outcome: AITaskLogOutcome
	var reason: AITaskLogReason?
	var error: String?
	var durationMilliseconds: Int?
	var feedCharacters: Int?
	var inputCharacters: Int?
	var outputCharacters: Int?
	var blocks: Int?
	var batchSize: Int?
	var fullText: Bool?
	var model: String?
	var attempts: Int?

	init(
		jobID: String,
		ts: String = "",
		kind: AITaskLogKind,
		articleID: String,
		title: String? = nil,
		url: String? = nil,
		trigger: AITaskLogTrigger,
		outcome: AITaskLogOutcome,
		reason: AITaskLogReason? = nil,
		error: String? = nil,
		durationMilliseconds: Int? = nil,
		feedCharacters: Int? = nil,
		inputCharacters: Int? = nil,
		outputCharacters: Int? = nil,
		blocks: Int? = nil,
		batchSize: Int? = nil,
		fullText: Bool? = nil,
		model: String? = nil,
		attempts: Int? = nil
	) {
		self.jobID = jobID
		self.ts = ts
		self.kind = kind
		self.articleID = articleID
		self.title = title
		self.url = url
		self.trigger = trigger
		self.outcome = outcome
		self.reason = reason
		self.error = error
		self.durationMilliseconds = durationMilliseconds
		self.feedCharacters = feedCharacters
		self.inputCharacters = inputCharacters
		self.outputCharacters = outputCharacters
		self.blocks = blocks
		self.batchSize = batchSize
		self.fullText = fullText
		self.model = model
		self.attempts = attempts
	}
}

extension AITaskTerminalEvent: Encodable {

	private enum CodingKeys: String, CodingKey {
		case ts
		case kind
		case articleID = "article_id"
		case title
		case url
		case trigger
		case outcome
		case reason
		case error
		case durationMilliseconds = "duration_ms"
		case feedCharacters = "feed_chars"
		case inputCharacters = "input_chars"
		case outputCharacters = "output_chars"
		case blocks
		case batchSize = "batch_size"
		case fullText = "full_text"
		case model
		case attempts
	}

	func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(ts, forKey: .ts)
		try container.encode(kind, forKey: .kind)
		try container.encode(articleID, forKey: .articleID)
		try container.encodeIfPresent(title, forKey: .title)
		try container.encodeIfPresent(url, forKey: .url)
		try container.encode(trigger, forKey: .trigger)
		try container.encode(outcome, forKey: .outcome)
		try container.encodeIfPresent(reason?.rawValue, forKey: .reason)
		try container.encodeIfPresent(error, forKey: .error)
		try container.encodeIfPresent(durationMilliseconds, forKey: .durationMilliseconds)
		try container.encodeIfPresent(feedCharacters, forKey: .feedCharacters)
		try container.encodeIfPresent(inputCharacters, forKey: .inputCharacters)
		try container.encodeIfPresent(outputCharacters, forKey: .outputCharacters)
		try container.encodeIfPresent(blocks, forKey: .blocks)
		try container.encodeIfPresent(batchSize, forKey: .batchSize)
		try container.encodeIfPresent(fullText, forKey: .fullText)
		try container.encodeIfPresent(model, forKey: .model)
		try container.encodeIfPresent(attempts, forKey: .attempts)
	}
}

/// A rejection or queue failure that never produced a job.
struct AITaskAttemptEvent: Sendable {
	var ts: String
	let kind: AITaskLogKind
	let articleID: String
	var title: String?
	var url: String?
	let trigger: AITaskLogTrigger
	let outcome: AITaskLogOutcome
	var reason: AITaskLogReason?
	var error: String?
	var batchSize: Int?

	init(
		ts: String = "",
		kind: AITaskLogKind,
		articleID: String,
		title: String? = nil,
		url: String? = nil,
		trigger: AITaskLogTrigger,
		outcome: AITaskLogOutcome,
		reason: AITaskLogReason? = nil,
		error: String? = nil,
		batchSize: Int? = nil
	) {
		self.ts = ts
		self.kind = kind
		self.articleID = articleID
		self.title = title
		self.url = url
		self.trigger = trigger
		self.outcome = outcome
		self.reason = reason
		self.error = error
		self.batchSize = batchSize
	}
}

extension AITaskAttemptEvent: Encodable {

	private enum CodingKeys: String, CodingKey {
		case ts
		case kind
		case articleID = "article_id"
		case title
		case url
		case trigger
		case outcome
		case reason
		case error
		case batchSize = "batch_size"
	}

	func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(ts, forKey: .ts)
		try container.encode(kind, forKey: .kind)
		try container.encode(articleID, forKey: .articleID)
		try container.encodeIfPresent(title, forKey: .title)
		try container.encodeIfPresent(url, forKey: .url)
		try container.encode(trigger, forKey: .trigger)
		try container.encode(outcome, forKey: .outcome)
		try container.encodeIfPresent(reason?.rawValue, forKey: .reason)
		try container.encodeIfPresent(error, forKey: .error)
		try container.encodeIfPresent(batchSize, forKey: .batchSize)
	}
}

protocol AITaskLogging: Sendable {

	func recordTerminal(_ event: AITaskTerminalEvent) async

	func recordAttempt(_ event: AITaskAttemptEvent) async
}

/// Appends one JSON object per line to a daily file under the app's AI folder.
///
/// Writes are serialized by the actor. I/O failures never affect the job: the
/// error goes to `os.Logger` and the task result is left alone.
actor AITaskLog: AITaskLogging {

	static let shared = AITaskLog()

	nonisolated private static let logger = Logger(subsystem: Logger.nnwSubsystem, category: "AITaskLog")
	private static let maximumRecordedJobs = 500
	private static let retentionDays = 30
	private static let fileNamePrefix = "ai-tasks-"
	private static let fileNameSuffix = ".jsonl"

	private let directoryProvider: @Sendable () -> URL?
	private let clock: @Sendable () -> Date
	private let writer: @Sendable (Data, URL) throws -> Void

	private var recordedJobIDs = Set<String>()
	private var recordedJobOrder: [String] = []
	private var attemptKeys = Set<String>()
	private var attemptDay: String?

	private let isoFormatter: ISO8601DateFormatter = {
		let formatter = ISO8601DateFormatter()
		formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		return formatter
	}()

	private let dayFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.timeZone = .current
		formatter.dateFormat = "yyyy-MM-dd"
		return formatter
	}()

	/// `directoryProvider` is injectable so tests can point at a temporary
	/// folder. The default resolves Application Support lazily and returns nil
	/// when the system has no such folder, which downgrades logging to
	/// `os.Logger` only.
	init(
		directoryProvider: (@Sendable () -> URL?)? = nil,
		clock: @escaping @Sendable () -> Date = { Date() },
		writer: @escaping @Sendable (Data, URL) throws -> Void = { data, url in
			try AITaskLog.append(data, to: url)
		}
	) {
		self.directoryProvider = directoryProvider ?? AITaskLog.defaultDirectory
		self.clock = clock
		self.writer = writer
	}

	func recordTerminal(_ event: AITaskTerminalEvent) async {
		guard recordJobID(event.jobID) else {
			return
		}
		let now = clock()
		var event = event
		event.ts = isoFormatter.string(from: now)
		write(event, now: now)
	}

	func recordAttempt(_ event: AITaskAttemptEvent) async {
		let now = clock()
		let day = dayFormatter.string(from: now)
		if attemptDay != day {
			attemptDay = day
			attemptKeys.removeAll()
		}
		let key = "\(event.articleID)|\(event.kind.rawValue)|\(event.reason?.rawValue ?? "")|\(day)"
		guard attemptKeys.insert(key).inserted else {
			return
		}
		var event = event
		event.ts = isoFormatter.string(from: now)
		write(event, now: now)
	}
}

private extension AITaskLog {

	static func defaultDirectory() -> URL? {
		guard let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
			return nil
		}
		return applicationSupport
			.appendingPathComponent("NetNewsWire", isDirectory: true)
			.appendingPathComponent("AI", isDirectory: true)
			.appendingPathComponent("logs", isDirectory: true)
	}

	/// Records the job ID, evicting the oldest entry after the cap.
	func recordJobID(_ jobID: String) -> Bool {
		guard recordedJobIDs.insert(jobID).inserted else {
			return false
		}
		recordedJobOrder.append(jobID)
		if recordedJobOrder.count > Self.maximumRecordedJobs {
			let evicted = recordedJobOrder.removeFirst()
			recordedJobIDs.remove(evicted)
		}
		return true
	}

	func write<T: Encodable>(_ event: T, now: Date) {
		guard let directory = directoryProvider() else {
			Self.logger.error("AI task log directory is unavailable")
			return
		}
		do {
			try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
			removeExpiredFiles(in: directory, now: now)
			let encoder = JSONEncoder()
			encoder.outputFormatting = [.sortedKeys]
			var data = try encoder.encode(event)
			data.append(0x0A)
			let fileURL = directory.appendingPathComponent(fileName(for: now), isDirectory: false)
			try writer(data, fileURL)
		} catch {
			Self.logger.error("Failed to write AI task log: \(String(describing: error), privacy: .public)")
		}
	}

	func fileName(for date: Date) -> String {
		Self.fileNamePrefix + dayFormatter.string(from: date) + Self.fileNameSuffix
	}

	/// Filenames use a sortable date, so a string comparison is enough. Today's
	/// file is always skipped.
	func removeExpiredFiles(in directory: URL, now: Date) {
		let todayName = fileName(for: now)
		let cutoffDate = Calendar.current.date(byAdding: .day, value: -Self.retentionDays, to: Calendar.current.startOfDay(for: now)) ?? now
		let cutoffName = fileName(for: cutoffDate)
		let contents = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
		for url in contents {
			let name = url.lastPathComponent
			guard name.hasPrefix(Self.fileNamePrefix), name.hasSuffix(Self.fileNameSuffix), name != todayName else {
				continue
			}
			guard name < cutoffName else {
				continue
			}
			try? FileManager.default.removeItem(at: url)
		}
	}

	static func append(_ data: Data, to url: URL) throws {
		guard FileManager.default.fileExists(atPath: url.path) else {
			try data.write(to: url, options: .atomic)
			return
		}
		let handle = try FileHandle(forWritingTo: url)
		defer {
			try? handle.close()
		}
		try handle.seekToEnd()
		try handle.write(contentsOf: data)
	}
}
