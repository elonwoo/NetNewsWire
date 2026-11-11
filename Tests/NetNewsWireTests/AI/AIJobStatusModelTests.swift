//
//  AIJobStatusModelTests.swift
//  NetNewsWireTests
//

import AI
import Foundation
import Testing

@testable import NetNewsWire

@Suite final class AIJobStatusModelTests {

	private let now = Date(timeIntervalSince1970: 1_700_000_000)

	// MARK: - Scope predicates

	@Test func feedScopeKeepsOnlyItsFeed() {
		let scope = AIJobScope(kind: .feed, name: "The Verge", feedIDs: ["feed-1"], feedCount: 1)
		let input = makeInput(
			scope: scope,
			active: [
				job(id: "j1", articleID: "a1", kind: .rewrite, status: .pending),
				job(id: "j2", articleID: "a2", kind: .rewrite, status: .pending)
			],
			articles: [
				article("a1", feedID: "feed-1"),
				article("a2", feedID: "feed-2")
			],
			articleCount: 231
		)

		let model = AIJobStatusModel.build(input)
		#expect(tile(model, "排队")?.count == 1)
		#expect(!model.footerLines.contains { $0.contains("不属于当前选择") })
		#expect(model.scopeSubtitle == "订阅源 · 231 篇")
	}

	@Test func folderScopeUsesEveryFlattenedFeed() {
		let scope = AIJobScope(kind: .folder, name: "Tech", feedIDs: ["feed-1", "feed-2"], feedCount: 2)
		let input = makeInput(
			scope: scope,
			active: [
				job(id: "j1", articleID: "a1", kind: .rewrite, status: .pending),
				job(id: "j2", articleID: "a2", kind: .rewrite, status: .pending),
				job(id: "j3", articleID: "a3", kind: .rewrite, status: .pending)
			],
			articles: [
				article("a1", feedID: "feed-1"),
				article("a2", feedID: "feed-2"),
				article("a3", feedID: "feed-3")
			],
			articleCount: 90
		)

		let model = AIJobStatusModel.build(input)
		#expect(tile(model, "排队")?.count == 2)
		#expect(!model.footerLines.contains { $0.contains("不属于当前选择") })
		#expect(model.scopeSubtitle == "文件夹 · 2 个订阅源 · 90 篇")
	}

	@Test func todayScopeUsesRollingDayAndFallsBackToArrival() {
		let scope = AIJobScope(kind: .today, name: "Today")
		let input = makeInput(
			scope: scope,
			active: [
				job(id: "recent-published", articleID: "recent-published", kind: .rewrite, status: .pending),
				job(id: "old-published", articleID: "old-published", kind: .rewrite, status: .pending),
				job(id: "recent-arrival", articleID: "recent-arrival", kind: .rewrite, status: .pending),
				job(id: "old-arrival", articleID: "old-arrival", kind: .rewrite, status: .pending)
			],
			articles: [
				article("recent-published", published: now.addingTimeInterval(-23 * 60 * 60)),
				article("old-published", published: now.addingTimeInterval(-25 * 60 * 60)),
				article("recent-arrival", published: nil, arrived: now.addingTimeInterval(-1 * 60 * 60)),
				article("old-arrival", published: nil, arrived: now.addingTimeInterval(-25 * 60 * 60))
			],
			articleCount: 12
		)

		let model = AIJobStatusModel.build(input)
		#expect(tile(model, "排队")?.count == 2)
		#expect(!model.footerLines.contains { $0.contains("不属于当前选择") })
		#expect(model.scopeSubtitle == "智能订阅 · 近 24 小时 · 12 篇")
	}

	@Test func allUnreadScopeUsesReadState() {
		let scope = AIJobScope(kind: .allUnread, name: "All Unread")
		let input = makeInput(
			scope: scope,
			active: [
				job(id: "j1", articleID: "unread", kind: .rewrite, status: .pending),
				job(id: "j2", articleID: "read", kind: .rewrite, status: .pending)
			],
			articles: [
				article("unread", read: false),
				article("read", read: true)
			],
			articleCount: 40
		)

		let model = AIJobStatusModel.build(input)
		#expect(tile(model, "排队")?.count == 1)
		#expect(!model.footerLines.contains { $0.contains("不属于当前选择") })
		#expect(model.scopeSubtitle == "智能订阅 · 全部未读 · 40 篇")
	}

	@Test func starredScopeUsesStarredState() {
		let scope = AIJobScope(kind: .starred, name: "Starred")
		let input = makeInput(
			scope: scope,
			active: [
				job(id: "j1", articleID: "starred", kind: .rewrite, status: .pending),
				job(id: "j2", articleID: "plain", kind: .rewrite, status: .pending)
			],
			articles: [
				article("starred", starred: true),
				article("plain", starred: false)
			],
			articleCount: 7
		)

		let model = AIJobStatusModel.build(input)
		#expect(tile(model, "排队")?.count == 1)
		#expect(!model.footerLines.contains { $0.contains("不属于当前选择") })
		#expect(model.scopeSubtitle == "智能订阅 · 已收藏 · 7 篇")
	}

	// MARK: - Out-of-scope counting

	@Test func outOfScopeTasksAreNotReportedInFooter() {
		let scope = AIJobScope(kind: .feed, name: "Feed", feedIDs: ["feed-1"], feedCount: 1)
		let input = makeInput(
			scope: scope,
			active: [
				job(id: "in", articleID: "a1", kind: .rewrite, status: .pending),
				job(id: "out-1", articleID: "a2", kind: .rewrite, status: .pending),
				job(id: "out-2", articleID: "a3", kind: .rewrite, status: .running, startedAt: now.addingTimeInterval(-10))
			],
			foldedFailures: [
				job(id: "failed-out", articleID: "a3", kind: .rewrite, status: .failed, attempts: 4, finishedAt: now.addingTimeInterval(-60), lastError: "boom")
			],
			articles: [
				article("a1", feedID: "feed-1"),
				article("a2", feedID: "feed-2"),
				article("a3", feedID: "feed-3")
			]
		)

		let model = AIJobStatusModel.build(input)
		#expect(tile(model, "排队")?.count == 1)
		#expect(tile(model, "进行中")?.count == 0)
		#expect(tile(model, "失败")?.count == 0)
		#expect(model.footerLines.contains("任务数字按任务条目计，头部篇数来自当前时间线。"))
		#expect(!model.footerLines.contains { $0.contains("不属于当前选择") })
	}

	// MARK: - Failures

	@Test func failureHiddenWhenSameArticleAndKindIsQueuedAgain() {
		let scope = AIJobScope(kind: .feed, name: "Feed", feedIDs: ["feed-1"], feedCount: 1)
		let failed = job(id: "failed", articleID: "a1", kind: .rewrite, status: .failed, attempts: 4, finishedAt: now.addingTimeInterval(-300), lastError: "boom")
		let requeued = job(id: "requeued", articleID: "a1", kind: .rewrite, status: .pending)

		let model = AIJobStatusModel.build(makeInput(
			scope: scope,
			active: [requeued],
			foldedFailures: [failed],
			articles: [article("a1")]
		))
		#expect(model.anomalies == nil)
		#expect(tile(model, "失败")?.count == 0)
		#expect(tile(model, "排队")?.count == 1)
		#expect(model.headline.text == "1 项排队中")
	}

	@Test func failedWindowIsTwentyFourHours() {
		let scope = AIJobScope(kind: .feed, name: "Feed", feedIDs: ["feed-1"], feedCount: 1)
		let input = makeInput(
			scope: scope,
			foldedFailures: [
				job(id: "recent", articleID: "a1", kind: .rewrite, status: .failed, attempts: 4, finishedAt: now.addingTimeInterval(-23 * 60 * 60), lastError: "boom"),
				job(id: "old", articleID: "a2", kind: .rewrite, status: .failed, attempts: 4, finishedAt: now.addingTimeInterval(-25 * 60 * 60), lastError: "boom")
			],
			articles: [article("a1"), article("a2")]
		)

		let model = AIJobStatusModel.build(input)
		#expect(model.anomalies?.totalCount == 1)
		#expect(model.anomalies?.groups.first?.count == 1)
		#expect(tile(model, "失败")?.count == 1)
		// Failures never enter the one-line state.
		#expect(model.headline.text == "没有正在进行中的任务")
		#expect(model.headline.tone == .gray)
	}

	@Test func similarErrorsMergeByKindAndReason() {
		let scope = AIJobScope(kind: .feed, name: "Feed", feedIDs: ["feed-1"], feedCount: 1)
		let failed = (0..<4).map { index in
			job(id: "f\(index)", articleID: "a\(index)", kind: .rewrite, status: .failed, attempts: 4, finishedAt: now.addingTimeInterval(-Double(index) * 60), lastError: "未配置模型 API key")
		}
		let articles = (0..<4).map { article("a\($0)") }
		let input = makeInput(scope: scope, foldedFailures: failed, articles: articles, hasAPIKey: false)

		let model = AIJobStatusModel.build(input)
		#expect(model.anomalies?.groups.count == 1)
		#expect(model.anomalies?.groups.first?.title == "4 项改写失败")
		#expect(model.anomalies?.groups.first?.reason == "未配置模型 API key")
		#expect(model.anomalies?.groups.first?.count == 4)
		#expect(model.showsGatewayBanner)
		#expect(model.headline.text == "AI 网关未配置")
		#expect(model.headline.tone == .red)
	}

	@Test func unconfiguredGatewayFailuresAlwaysMerge() {
		let scope = AIJobScope(kind: .feed, name: "Feed", feedIDs: ["feed-1"], feedCount: 1)
		let failed = (0..<2).map { index in
			job(id: "f\(index)", articleID: "a\(index)", kind: .rewrite, status: .failed, attempts: 1, finishedAt: now.addingTimeInterval(-Double(index) * 60), lastError: "未配置模型 API key")
		}
		let input = makeInput(scope: scope, foldedFailures: failed, articles: [article("a0"), article("a1")], hasAPIKey: false)

		let model = AIJobStatusModel.build(input)
		#expect(model.anomalies?.groups.count == 1)
		#expect(model.anomalies?.groups.first?.title == "2 项改写失败")
		#expect(model.anomalies?.groups.first?.retryableJobs.count == 2)
	}

	@Test func unknownArticleJobsStayOutOfScope() {
		let scope = AIJobScope(kind: .feed, name: "Feed", feedIDs: ["feed-1"], feedCount: 1)
		let input = makeInput(
			scope: scope,
			active: [job(id: "active-gone", articleID: "gone", kind: .rewrite, status: .pending)],
			foldedFailures: [job(id: "failed-gone", articleID: "also-gone", kind: .rewrite, status: .failed, attempts: 4, finishedAt: now.addingTimeInterval(-60), lastError: "找不到文章")]
		)

		let model = AIJobStatusModel.build(input)
		#expect(tile(model, "排队")?.count == 0)
		#expect(tile(model, "进行中")?.count == 0)
		#expect(model.anomalies == nil)
		#expect(!model.footerLines.contains { $0.contains("不属于当前选择") })
		#expect(model.headline.text == "没有正在进行中的任务")
	}

	@Test func retryCountsAreDeduplicatedByArticleAndKind() {
		let scope = AIJobScope(kind: .feed, name: "Feed", feedIDs: ["feed-1"], feedCount: 1)
		let retries = [
			job(id: "retry-1", articleID: "a1", kind: .rewrite, status: .retry, attempts: 1, availableAt: now, lastError: "boom"),
			job(id: "retry-2", articleID: "a1", kind: .rewrite, status: .retry, attempts: 1, availableAt: now.addingTimeInterval(60), lastError: "boom")
		]

		let model = AIJobStatusModel.build(makeInput(scope: scope, active: retries, articles: [article("a1")]))
		#expect(tile(model, "等待重试")?.count == 1)
		#expect(model.headline.text == "没有正在进行中的任务")
		#expect(model.anomalies == nil)
	}

	@Test func anomalyGroupsCountPerFeed() {
		let scope = AIJobScope(kind: .feed, name: "Feed", feedIDs: ["feed-1", "feed-2"], feedCount: 2)
		let input = makeInput(
			scope: scope,
			foldedFailures: [
				job(id: "f1", articleID: "a1", kind: .rewrite, status: .failed, attempts: 1, finishedAt: now.addingTimeInterval(-10), lastError: "boom"),
				job(id: "f2", articleID: "a2", kind: .rewrite, status: .failed, attempts: 1, finishedAt: now.addingTimeInterval(-20), lastError: "boom")
			],
			articles: [
				article("a1", feedID: "feed-1", feedName: "Beta"),
				article("a2", feedID: "feed-2", feedName: "Alpha")
			]
		)

		let group = AIJobStatusModel.build(input).anomalies?.groups.first
		#expect(group?.count == 2)
		#expect(group?.perFeedCounts.map(\.feedName) == ["Alpha", "Beta"])
		#expect(group?.perFeedCounts.map(\.count) == [1, 1])
		#expect(group?.perFeedCounts.reduce(0) { $0 + $1.count } == group?.count)
	}

	@Test func retryableJobsAreDeduplicatedByArticleAndKind() {
		let scope = AIJobScope(kind: .feed, name: "Feed", feedIDs: ["feed-1"], feedCount: 1)
		let input = makeInput(
			scope: scope,
			foldedFailures: [
				job(id: "f1", articleID: "a1", kind: .rewrite, status: .failed, attempts: 1, finishedAt: now.addingTimeInterval(-10), lastError: "boom"),
				job(id: "f2", articleID: "a1", kind: .rewrite, status: .failed, attempts: 1, finishedAt: now.addingTimeInterval(-20), lastError: "boom")
			],
			articles: [article("a1")]
		)

		let group = AIJobStatusModel.build(input).anomalies?.groups.first
		#expect(group?.count == 2)
		#expect(group?.retryableJobs == [AIJobRequeueRequest(articleID: "a1", kind: .rewrite)])
	}

	@Test func anomalyGroupsOrderRewriteBeforeTranslations() {
		let scope = AIJobScope(kind: .feed, name: "Feed", feedIDs: ["feed-1"], feedCount: 1)
		let input = makeInput(
			scope: scope,
			foldedFailures: [
				job(id: "t1", articleID: "a1", kind: .titleTranslation, status: .failed, attempts: 1, finishedAt: now.addingTimeInterval(-10), lastError: "boom"),
				job(id: "b1", articleID: "a2", kind: .bodyTranslation, status: .failed, attempts: 1, finishedAt: now.addingTimeInterval(-10), lastError: "boom"),
				job(id: "r1", articleID: "a3", kind: .rewrite, status: .failed, attempts: 1, finishedAt: now.addingTimeInterval(-10), lastError: "boom")
			],
			articles: [article("a1"), article("a2"), article("a3")]
		)

		let groups = AIJobStatusModel.build(input).anomalies?.groups ?? []
		#expect(groups.map(\.kind) == [.rewrite, .bodyTranslation, .titleTranslation])
	}

	@Test func anomalyGroupsOrderKindsBeforeCount() {
		let scope = AIJobScope(kind: .feed, name: "Feed", feedIDs: ["feed-1"], feedCount: 1)
		let input = makeInput(
			scope: scope,
			foldedFailures: [
				job(id: "r1", articleID: "a1", kind: .rewrite, status: .failed, attempts: 1, finishedAt: now.addingTimeInterval(-10), lastError: "boom"),
				job(id: "r2", articleID: "a2", kind: .rewrite, status: .failed, attempts: 1, finishedAt: now.addingTimeInterval(-10), lastError: "boom"),
				job(id: "b1", articleID: "a3", kind: .bodyTranslation, status: .failed, attempts: 1, finishedAt: now.addingTimeInterval(-10), lastError: "boom"),
				job(id: "t1", articleID: "a4", kind: .titleTranslation, status: .failed, attempts: 1, finishedAt: now.addingTimeInterval(-10), lastError: "boom"),
				job(id: "t2", articleID: "a5", kind: .titleTranslation, status: .failed, attempts: 1, finishedAt: now.addingTimeInterval(-10), lastError: "boom"),
				job(id: "t3", articleID: "a6", kind: .titleTranslation, status: .failed, attempts: 1, finishedAt: now.addingTimeInterval(-10), lastError: "boom"),
				job(id: "t4", articleID: "a7", kind: .titleTranslation, status: .failed, attempts: 1, finishedAt: now.addingTimeInterval(-10), lastError: "boom"),
				job(id: "t5", articleID: "a8", kind: .titleTranslation, status: .failed, attempts: 1, finishedAt: now.addingTimeInterval(-10), lastError: "boom")
			],
			articles: (1...8).map { article("a\($0)") }
		)

		let groups = AIJobStatusModel.build(input).anomalies?.groups ?? []
		#expect(groups.map(\.kind) == [.rewrite, .bodyTranslation, .titleTranslation])
		#expect(groups.map(\.count) == [2, 1, 5])
	}

	@Test func expandedFailureGroupSurvivesRebuild() {
		let scope = AIJobScope(kind: .feed, name: "Feed", feedIDs: ["feed-1"], feedCount: 1)
		let key = AIJobFailureGroupKey(kind: .rewrite, reason: "boom")
		let first = AIJobStatusModel.build(makeInput(
			scope: scope,
			foldedFailures: [
				job(id: "f1", articleID: "a1", kind: .rewrite, status: .failed, attempts: 1, finishedAt: now.addingTimeInterval(-10), lastError: "boom")
			],
			articles: [article("a1")],
			expanded: [key]
		))
		#expect(first.anomalies?.groups.first?.isExpanded == true)

		let second = AIJobStatusModel.build(makeInput(
			scope: scope,
			foldedFailures: [
				job(id: "f1", articleID: "a1", kind: .rewrite, status: .failed, attempts: 1, finishedAt: now.addingTimeInterval(-10), lastError: "boom"),
				job(id: "f2", articleID: "a2", kind: .rewrite, status: .failed, attempts: 1, finishedAt: now.addingTimeInterval(-20), lastError: "boom")
			],
			articles: [article("a1"), article("a2")],
			expanded: [key]
		))
		#expect(second.anomalies?.groups.first?.isExpanded == true)
		#expect(second.anomalies?.groups.first?.count == 2)
	}

	// MARK: - Status line and tiles

	@Test func headlineCoversSixStates() {
		let cases: [(Bool, Int, Int, Int, String, AIJobStatusTone)] = [
			(false, 2, 1, 5, "AI 网关未配置", .red),
			(true, 1, 0, 0, "正在改写 1 篇", .green),
			(true, 0, 3, 0, "正在翻译 3 篇", .green),
			(true, 2, 3, 0, "正在改写 2 篇、翻译 3 篇", .green),
			(true, 0, 0, 7, "7 项排队中", .yellow),
			(true, 0, 0, 0, "没有正在进行中的任务", .gray)
		]
		for entry in cases {
			let headline = AIJobStatusModel.headline(
				hasAPIKey: entry.0,
				runningRewriteArticleCount: entry.1,
				runningTranslationArticleCount: entry.2,
				pendingCount: entry.3
			)
			#expect(headline.text == entry.4)
			#expect(headline.tone == entry.5)
		}
	}

	@Test func headlineCountsUniqueArticlesWhileTilesCountJobs() {
		let scope = AIJobScope(kind: .feed, name: "Feed", feedIDs: ["feed-1"], feedCount: 1)
		let input = makeInput(
			scope: scope,
			active: [
				job(id: "r1", articleID: "a1", kind: .rewrite, status: .running, startedAt: now),
				job(id: "r2", articleID: "a1", kind: .rewrite, status: .running, startedAt: now)
			],
			articles: [article("a1")]
		)

		let model = AIJobStatusModel.build(input)
		#expect(model.headline.text == "正在改写 1 篇")
		#expect(tile(model, "进行中")?.count == 2)
	}

	@Test func tilesAndFailureGroupsShareTheSameFailureSet() {
		let scope = AIJobScope(kind: .feed, name: "Feed", feedIDs: ["feed-1"], feedCount: 1)
		let input = makeInput(
			scope: scope,
			foldedFailures: [
				job(id: "f1", articleID: "a1", kind: .rewrite, status: .failed, attempts: 1, finishedAt: now.addingTimeInterval(-10), lastError: "boom"),
				job(id: "f2", articleID: "a2", kind: .rewrite, status: .failed, attempts: 1, finishedAt: now.addingTimeInterval(-20), lastError: "boom"),
				job(id: "f3", articleID: "a3", kind: .bodyTranslation, status: .failed, attempts: 1, finishedAt: now.addingTimeInterval(-30), lastError: "empty")
			],
			articles: [article("a1"), article("a2"), article("a3")]
		)

		let model = AIJobStatusModel.build(input)
		let groups = model.anomalies?.groups ?? []
		#expect(tile(model, "失败")?.count == model.anomalies?.totalCount)
		#expect(tile(model, "失败")?.count == groups.reduce(0) { $0 + $1.count })
		#expect(groups.reduce(0) { $0 + $1.retryableJobs.count } == 3)
	}

	@Test func tilesKeepZeroCountsWithNeutralTone() {
		let model = AIJobStatusModel.build(makeInput(scope: AIJobScope(kind: .starred, name: "Starred")))
		#expect(model.tiles.map(\.title) == ["进行中", "排队", "等待重试", "失败"])
		#expect(model.tiles.map(\.count) == [0, 0, 0, 0])
		#expect(model.tiles.allSatisfy { $0.tone == .neutral })
	}

	@Test func tilesColorOnlyNonZeroCounts() {
		let scope = AIJobScope(kind: .feed, name: "Feed", feedIDs: ["feed-1"], feedCount: 1)
		let input = makeInput(
			scope: scope,
			active: [
				job(id: "r1", articleID: "a1", kind: .rewrite, status: .running, startedAt: now),
				job(id: "p1", articleID: "a2", kind: .rewrite, status: .pending),
				job(id: "t1", articleID: "a3", kind: .rewrite, status: .retry, attempts: 1, availableAt: now.addingTimeInterval(60), lastError: "boom")
			],
			foldedFailures: [
				job(id: "f1", articleID: "a4", kind: .rewrite, status: .failed, attempts: 1, finishedAt: now.addingTimeInterval(-60), lastError: "boom")
			],
			articles: (1...4).map { article("a\($0)") }
		)

		let tiles = AIJobStatusModel.build(input).tiles
		#expect(tiles[0].tone == .accent)
		#expect(tiles[1].tone == .neutral)
		#expect(tiles[2].tone == .retry)
		#expect(tiles[3].tone == .danger)
	}

	// MARK: - Read filter

	@Test func unreadOnlyHidesReadArticleJobsFromEveryCount() {
		let scope = AIJobScope(kind: .feed, name: "Feed", feedIDs: ["feed-1"], feedCount: 1)
		let input = makeInput(
			scope: scope,
			active: [
				job(id: "pending-read", articleID: "read", kind: .rewrite, status: .pending),
				job(id: "pending-unread", articleID: "unread", kind: .rewrite, status: .pending)
			],
			foldedFailures: [
				job(id: "failed-read", articleID: "read", kind: .bodyTranslation, status: .failed, attempts: 4, finishedAt: now.addingTimeInterval(-60), lastError: "boom"),
				job(id: "failed-unread", articleID: "unread", kind: .bodyTranslation, status: .failed, attempts: 4, finishedAt: now.addingTimeInterval(-60), lastError: "boom")
			],
			completedToday: [
				job(id: "done-read", articleID: "read", kind: .rewrite, status: .completed, finishedAt: now.addingTimeInterval(-60)),
				job(id: "done-unread", articleID: "unread", kind: .rewrite, status: .completed, finishedAt: now.addingTimeInterval(-60))
			],
			articles: [article("read", read: true), article("unread", read: false)],
			unreadOnly: true
		)

		let model = AIJobStatusModel.build(input)
		#expect(tile(model, "排队")?.count == 1)
		#expect(tile(model, "失败")?.count == 1)
		#expect(model.anomalies?.totalCount == 1)
		#expect(model.activity?.totalCount == 1)
		#expect(model.headline.text == "1 项排队中")
	}

	@Test func turningOffReadFilterBringsReadArticleJobsBack() {
		let scope = AIJobScope(kind: .feed, name: "Feed", feedIDs: ["feed-1"], feedCount: 1)
		let input = makeInput(
			scope: scope,
			active: [
				job(id: "pending-read", articleID: "read", kind: .rewrite, status: .pending),
				job(id: "pending-unread", articleID: "unread", kind: .rewrite, status: .pending)
			],
			foldedFailures: [
				job(id: "failed-read", articleID: "read", kind: .bodyTranslation, status: .failed, attempts: 4, finishedAt: now.addingTimeInterval(-60), lastError: "boom"),
				job(id: "failed-unread", articleID: "unread", kind: .bodyTranslation, status: .failed, attempts: 4, finishedAt: now.addingTimeInterval(-60), lastError: "boom")
			],
			completedToday: [
				job(id: "done-read", articleID: "read", kind: .rewrite, status: .completed, finishedAt: now.addingTimeInterval(-60)),
				job(id: "done-unread", articleID: "unread", kind: .rewrite, status: .completed, finishedAt: now.addingTimeInterval(-60))
			],
			articles: [article("read", read: true), article("unread", read: false)],
			unreadOnly: false
		)

		let model = AIJobStatusModel.build(input)
		#expect(tile(model, "排队")?.count == 2)
		#expect(tile(model, "失败")?.count == 2)
		#expect(model.anomalies?.totalCount == 2)
		#expect(model.activity?.totalCount == 2)
	}

	@Test func requeuedFailureStaysMaskedInTilesAndAnomalies() {
		let scope = AIJobScope(kind: .feed, name: "Feed", feedIDs: ["feed-1"], feedCount: 1)
		let failed = job(id: "failed", articleID: "a1", kind: .rewrite, status: .failed, attempts: 4, finishedAt: now.addingTimeInterval(-300), lastError: "boom")
		let requeued = job(id: "requeued", articleID: "a1", kind: .rewrite, status: .pending)
		let model = AIJobStatusModel.build(makeInput(
			scope: scope,
			active: [requeued],
			foldedFailures: [failed],
			articles: [article("a1")]
		))

		#expect(model.headline.text == "1 项排队中")
		#expect(tile(model, "失败")?.count == 0)
		#expect(model.anomalies == nil)
	}

	// MARK: - Activity

	@Test func activityCountsOnlyInScopeJobsFromToday() {
		let scope = AIJobScope(kind: .feed, name: "Feed", feedIDs: ["feed-1"], feedCount: 1)
		let articles = [
			article("in-1", feedID: "feed-1"),
			article("in-2", feedID: "feed-1"),
			article("out", feedID: "feed-2")
		]
		let input = makeInput(
			scope: scope,
			completedToday: [
				job(id: "title-1", articleID: "in-1", kind: .titleTranslation, status: .completed, finishedAt: now.addingTimeInterval(-60)),
				job(id: "title-2", articleID: "in-2", kind: .titleTranslation, status: .completed, finishedAt: now.addingTimeInterval(-120)),
				job(id: "rewrite-in", articleID: "in-1", kind: .rewrite, status: .completed, finishedAt: now.addingTimeInterval(-60)),
				job(id: "rewrite-out", articleID: "out", kind: .rewrite, status: .completed, finishedAt: now.addingTimeInterval(-60)),
				job(id: "rewrite-yesterday", articleID: "in-2", kind: .rewrite, status: .completed, finishedAt: AIJobStatusModel.startOfDay(for: now).addingTimeInterval(-1))
			],
			articles: articles
		)

		let model = AIJobStatusModel.build(input)
		#expect(model.activity?.items.map(\.kind) == [.rewrite, .titleTranslation])
		#expect(model.activity?.items.map(\.count) == [1, 2])
		#expect(model.activity?.totalCount == 3)
		#expect(model.activity?.lastActivityText == "上次活动 1 分钟前")
	}

	@Test func activityOmitsKindsWithZeroCompletions() {
		let scope = AIJobScope(kind: .feed, name: "Feed", feedIDs: ["feed-1"], feedCount: 1)
		let input = makeInput(
			scope: scope,
			completedToday: [
				job(id: "rewrite-1", articleID: "a1", kind: .rewrite, status: .completed, finishedAt: now.addingTimeInterval(-60))
			],
			articles: [article("a1")]
		)

		let model = AIJobStatusModel.build(input)
		#expect(model.activity?.items.map(\.kind) == [.rewrite])
		#expect(model.activity?.items.map(\.count) == [1])
	}

	@Test func activityLastActivityUsesNewestFinishedAt() {
		let scope = AIJobScope(kind: .feed, name: "Feed", feedIDs: ["feed-1"], feedCount: 1)
		let input = makeInput(
			scope: scope,
			completedToday: [
				job(id: "older", articleID: "a1", kind: .rewrite, status: .completed, finishedAt: now.addingTimeInterval(-3 * 60 * 60)),
				job(id: "newer", articleID: "a2", kind: .titleTranslation, status: .completed, finishedAt: now.addingTimeInterval(-2 * 60 * 60))
			],
			articles: [article("a1"), article("a2")]
		)

		let model = AIJobStatusModel.build(input)
		#expect(model.activity?.lastActivityText == "上次活动 2 小时前")
	}

	@Test func activityHiddenWithoutTodayCompletions() {
		let scope = AIJobScope(kind: .feed, name: "Feed", feedIDs: ["feed-1"], feedCount: 1)
		let input = makeInput(
			scope: scope,
			completedToday: [
				job(id: "yesterday", articleID: "a1", kind: .rewrite, status: .completed, finishedAt: AIJobStatusModel.startOfDay(for: now).addingTimeInterval(-1))
			],
			articles: [article("a1")]
		)

		let model = AIJobStatusModel.build(input)
		#expect(model.activity == nil)
		#expect(model.footerLines == ["任务数字按任务条目计，头部篇数来自当前时间线。"])
	}

	// MARK: - Empty state

	@Test func emptyStateShowsTwoFlowHints() {
		let scope = AIJobScope(kind: .feed, name: "The Verge", feedIDs: ["feed-1"], feedCount: 1)
		let configured = AIJobStatusModel.build(makeInput(scope: scope))
		#expect(configured.emptyStateLines == [
			"新文章：改写、标题翻译自动排队",
			"正文翻译：打开「翻译」标签时开始"
		])
		#expect(configured.headline.text == "没有正在进行中的任务")
		#expect(configured.headline.tone == .gray)
		#expect(configured.footerLines.contains("任务数字按任务条目计，头部篇数来自当前时间线。"))

		let unconfigured = AIJobStatusModel.build(makeInput(scope: scope, hasAPIKey: false))
		#expect(unconfigured.emptyStateLines.first == "配置 AI 网关后，新文章才会开始排队")

		let withWork = AIJobStatusModel.build(makeInput(
			scope: scope,
			active: [job(id: "p", articleID: "a1", kind: .rewrite, status: .pending)],
			articles: [article("a1")]
		))
		#expect(withWork.emptyStateLines.isEmpty)
	}

	// MARK: - Gateway

	@Test func gatewayBannerAndBoardStayUsableWithoutAPIKey() {
		let scope = AIJobScope(kind: .feed, name: "Feed", feedIDs: ["feed-1"], feedCount: 1)
		let coverage = AIJobCoverageBuilder.build(
			articles: [article("a1")],
			unreadOnly: false,
			feedDisplayNames: ["feed-1": "Feed"],
			translatedArticleIDs: [],
			rewrittenArticleIDs: []
		)
		let model = AIJobStatusModel.build(makeInput(
			scope: scope,
			active: [job(id: "p", articleID: "a1", kind: .rewrite, status: .pending)],
			articles: [article("a1")],
			hasAPIKey: false,
			coverage: coverage
		))

		#expect(model.showsGatewayBanner == true)
		#expect(model.headline.text == "AI 网关未配置")
		#expect(model.headline.tone == .red)
		#expect(tile(model, "排队")?.count == 1)
		#expect(model.coverage?.total == 1)
	}

	// MARK: - Coverage

	@Test func coverageGroupsByFeedAndSortsByCountThenNameThenID() {
		let articles = [
			info("a1", feedID: "feed-1", feedName: "Beta"),
			info("a2", feedID: "feed-1", feedName: "Beta"),
			info("b1", feedID: "feed-2", feedName: "Alpha"),
			info("c1", feedID: "feed-3", feedName: "Alpha")
		]
		let coverage = AIJobCoverageBuilder.build(
			articles: articles,
			unreadOnly: false,
			feedDisplayNames: ["feed-1": "Beta", "feed-2": "Alpha", "feed-3": "Alpha"],
			translatedArticleIDs: [],
			rewrittenArticleIDs: []
		)

		#expect(coverage.rows.map(\.feedID) == ["feed-1", "feed-2", "feed-3"])
		#expect(coverage.rows.map(\.feedName) == ["Beta", "Alpha", "Alpha"])
		#expect(coverage.rows.map(\.total) == [2, 1, 1])
	}

	@Test func coverageCountsOverlapInBothColumnsAndOriginalAsComplement() {
		let articles = [
			info("a1", feedID: "feed-1"),
			info("a2", feedID: "feed-1"),
			info("a3", feedID: "feed-1")
		]
		let coverage = AIJobCoverageBuilder.build(
			articles: articles,
			unreadOnly: false,
			feedDisplayNames: ["feed-1": "Feed"],
			translatedArticleIDs: ["a1"],
			rewrittenArticleIDs: ["a1", "a2"]
		)

		let row = coverage.rows[0]
		#expect(row.translated == 1)
		#expect(row.rewritten == 2)
		#expect(row.original == 1)
		#expect(row.translatedOnly == 0)
		#expect(row.translatedOnly + row.rewritten + row.original == row.total)
		#expect(coverage.translated == 1)
		#expect(coverage.rewritten == 2)
		#expect(coverage.original == 1)
		#expect(coverage.translatedOnly == 0)
		#expect(coverage.translatedOnly == coverage.rows.reduce(0) { $0 + $1.translatedOnly })
		#expect(coverage.translatedOnly == coverage.total - coverage.rewritten - coverage.original)
		#expect(coverage.rows.allSatisfy { $0.translatedOnly >= 0 })
	}

	@Test func coverageTranslatedOnlySplitsOverlapAndAggregatesRows() {
		let articles = [
			info("a1", feedID: "feed-1"),
			info("a2", feedID: "feed-1"),
			info("a3", feedID: "feed-1"),
			info("a4", feedID: "feed-1"),
			info("b1", feedID: "feed-2"),
			info("b2", feedID: "feed-2")
		]
		let coverage = AIJobCoverageBuilder.build(
			articles: articles,
			unreadOnly: false,
			feedDisplayNames: ["feed-1": "Feed 1", "feed-2": "Feed 2"],
			translatedArticleIDs: ["a1", "a2", "b1"],
			rewrittenArticleIDs: ["a2", "a3"]
		)

		for row in coverage.rows {
			#expect(row.translatedOnly >= 0)
			#expect(row.translatedOnly + row.rewritten + row.original == row.total)
		}
		#expect(coverage.rows.map(\.translatedOnly) == [1, 1])
		#expect(coverage.translatedOnly == coverage.rows.reduce(0) { $0 + $1.translatedOnly })
		#expect(coverage.translatedOnly == coverage.total - coverage.rewritten - coverage.original)
		#expect(coverage.translatedOnly == 2)
	}

	@Test func coverageHonoursUnreadOnly() {
		let articles = [
			info("read", feedID: "feed-1", read: true),
			info("unread", feedID: "feed-1", read: false)
		]
		let coverage = AIJobCoverageBuilder.build(
			articles: articles,
			unreadOnly: true,
			feedDisplayNames: ["feed-1": "Feed"],
			translatedArticleIDs: ["read"],
			rewrittenArticleIDs: []
		)

		#expect(coverage.total == 1)
		#expect(coverage.translated == 0)
		#expect(coverage.rows.first?.total == 1)
	}

	@Test func coverageSingleFeedHasOneRowAndTotalsMatchList() {
		let articles = [
			info("a1", feedID: "feed-1"),
			info("a2", feedID: "feed-1")
		]
		let coverage = AIJobCoverageBuilder.build(
			articles: articles,
			unreadOnly: false,
			feedDisplayNames: ["feed-1": "Feed"],
			translatedArticleIDs: [],
			rewrittenArticleIDs: []
		)

		#expect(coverage.rows.count == 1)
		#expect(coverage.rows.reduce(0) { $0 + $1.total } == articles.count)
		#expect(coverage.total == articles.count)
	}

	@Test func coverageEmptyListHasNoRows() {
		let coverage = AIJobCoverageBuilder.build(
			articles: [],
			unreadOnly: false,
			feedDisplayNames: [:],
			translatedArticleIDs: [],
			rewrittenArticleIDs: []
		)

		#expect(coverage.rows.isEmpty)
		#expect(coverage.total == 0)
	}

	@Test func coverageUsesFeedNameFallbackOrder() {
		#expect(AIJobCoverageBuilder.feedDisplayName(feedName: "Name", urlHost: "host", feedID: "id") == "Name")
		#expect(AIJobCoverageBuilder.feedDisplayName(feedName: nil, urlHost: "host", feedID: "id") == "host")
		#expect(AIJobCoverageBuilder.feedDisplayName(feedName: "   ", urlHost: "host", feedID: "id") == "host")
		#expect(AIJobCoverageBuilder.feedDisplayName(feedName: nil, urlHost: nil, feedID: "id") == "id")
	}

	@Test func coverageQueryFailureHidesOnlyCoverage() {
		let scope = AIJobScope(kind: .feed, name: "Feed", feedIDs: ["feed-1"], feedCount: 1)
		let coverage = AIJobCoverageBuilder.build(
			articles: [article("a1")],
			unreadOnly: false,
			feedDisplayNames: ["feed-1": "Feed"],
			translatedArticleIDs: [],
			rewrittenArticleIDs: []
		)
		let model = AIJobStatusModel.build(makeInput(
			scope: scope,
			active: [job(id: "p", articleID: "a1", kind: .rewrite, status: .pending)],
			articles: [article("a1")],
			coverage: coverage,
			coverageQueryFailed: true
		))

		#expect(model.coverage == nil)
		#expect(model.coverageUnavailable)
		#expect(model.headline.text == "1 项排队中")
		#expect(tile(model, "排队")?.count == 1)
		#expect(model.footerLines.isEmpty == false)
	}

	@Test func coverageEmptyStateMessageForEmptyList() {
		let scope = AIJobScope(kind: .feed, name: "Feed", feedIDs: ["feed-1"], feedCount: 1)
		let coverage = AIJobCoverageBuilder.build(
			articles: [],
			unreadOnly: false,
			feedDisplayNames: [:],
			translatedArticleIDs: [],
			rewrittenArticleIDs: []
		)
		let model = AIJobStatusModel.build(makeInput(scope: scope, coverage: coverage))

		#expect(model.coverage?.total == 0)
		#expect(model.coverageUnavailable == false)
		#expect(model.coverageEmptyMessage == "列表内没有文章")
	}

	// MARK: - Batch retry

	@MainActor
	@Test func batchRetryDeduplicatesSameRequestAcrossDoubleClick() async {
		let enqueuer = RecordingRetryEnqueuer()
		enqueuer.delay = .milliseconds(30)
		let runner = AIJobFailureRetryRunner(enqueuer: enqueuer)
		let request = AIJobRequeueRequest(articleID: "a1", kind: .rewrite)

		async let first = runner.retry([request, request])
		async let second = runner.retry([request])
		let firstOutcome = await first
		let secondOutcome = await second

		#expect(enqueuer.requests.count == 1)
		#expect(firstOutcome.submittedCount + secondOutcome.submittedCount == 1)
		#expect(firstOutcome.skippedCount + secondOutcome.skippedCount == 2)
	}

	@MainActor
	@Test func manualRetryAndCatchUpQueueOneRewrite() async throws {
		let databasePath = FileManager.default.temporaryDirectory
			.appendingPathComponent("AIJobStatusModelTests-\(UUID().uuidString).sqlite")
			.path
		let store = SQLiteAIStore(databasePath: databasePath)
		let queue = AIQueue(store: store)
		defer {
			try? FileManager.default.removeItem(atPath: databasePath)
			try? FileManager.default.removeItem(atPath: databasePath + "-wal")
			try? FileManager.default.removeItem(atPath: databasePath + "-shm")
		}

		let previous = AppDefaults.aiAutoRewriteEnabled
		AppDefaults.aiAutoRewriteEnabled = true
		defer {
			AppDefaults.aiAutoRewriteEnabled = previous
		}

		let article = AIArticle(
			id: "race",
			title: "English title",
			contentText: String(repeating: "a", count: 2500),
			publishedAt: now
		)
		let config = AIConfig(model: "test-model")
		let engine = AIEngine(store: store, client: NoCallClient(), config: config)
		let executor = AIJobExecutor(
			store: store,
			queue: queue,
			resolver: FixedResolver(article: article),
			services: {
				AIJobServices(
					translation: AITranslationService(store: store, engine: engine, config: config),
					rewrite: AIRewriteService(store: store, engine: engine),
					model: config.model
				)
			},
			isConfigured: { true },
			notificationCenter: NotificationCenter(),
			autoStart: false,
			catchUpSourceProvider: { AICatchUpSource(articles: [article]) },
			chineseAllowedFeedIDsProvider: { [] },
			autoWorkDisabled: false,
			taskLog: NoTaskLog()
		)
		let enqueuer = AIJobExecutorRetryEnqueuer(executor: executor, store: store)
		let runner = AIJobFailureRetryRunner(enqueuer: enqueuer)
		let request = AIJobRequeueRequest(articleID: "race", kind: .rewrite)

		async let manual = runner.retry([request])
		async let catchUp: Void = executor.catchUpMissedWork()
		let outcome = await manual
		await catchUp

		let rewrites = try await store.activeJobs().filter { $0.kind == .rewrite && $0.articleID == "race" }
		#expect(rewrites.count == 1)
		#expect(outcome.submittedCount + outcome.skippedCount == 1)
	}

	// MARK: - Timeline notification wiring

	@MainActor
	@Test func timelineNotificationInvokesInjectedRefresh() async {
		let center = NotificationCenter()
		let controller = MainWindowController(windowNibName: "MainWindow")
		controller.aiJobPanelRefreshCenter = center
		var calls = 0
		controller.aiJobPanelRefreshHandler = {
			calls += 1
		}
		controller.installTimelineRefreshObservation()

		center.post(name: .aiTimelineArticlesDidChange, object: nil)
		await Task.yield()

		#expect(calls == 1)
	}

	// MARK: - Helpers

	private func tile(_ model: AIJobStatusViewModel, _ title: String) -> AIJobTile? {
		model.tile(title)
	}

	private func article(
		_ articleID: String,
		feedID: String = "feed-1",
		feedName: String? = nil,
		published: Date? = nil,
		arrived: Date? = nil,
		read: Bool = false,
		starred: Bool = false
	) -> AIJobArticleInfo {
		AIJobArticleInfo(
			articleID: articleID,
			title: "Title \(articleID)",
			feedID: feedID,
			feedName: feedName ?? "Feed \(feedID)",
			datePublished: published,
			dateArrived: arrived ?? now,
			read: read,
			starred: starred
		)
	}

	private func info(
		_ articleID: String,
		feedID: String,
		feedName: String? = nil,
		read: Bool = false
	) -> AIJobArticleInfo {
		article(articleID, feedID: feedID, feedName: feedName, read: read)
	}

	private func job(
		id: String,
		articleID: String,
		kind: AIJobKind,
		status: AIJobStatus,
		attempts: Int = 0,
		availableAt: Date? = nil,
		startedAt: Date? = nil,
		finishedAt: Date? = nil,
		lastError: String? = nil
	) -> AIJob {
		AIJob(
			id: id,
			articleID: articleID,
			kind: kind,
			priority: priority(for: kind),
			status: status,
			attempts: attempts,
			availableAt: availableAt ?? now,
			leaseUntil: nil,
			lastError: lastError,
			startedAt: startedAt,
			finishedAt: finishedAt,
			createdAt: now
		)
	}

	private func priority(for kind: AIJobKind) -> Int {
		switch kind {
		case .bodyTranslation: return 100
		case .titleTranslation: return 50
		case .rewrite: return 10
		}
	}

	private func makeInput(
		scope: AIJobScope,
		active: [AIJob] = [],
		foldedFailures: [AIJob] = [],
		completedToday: [AIJob] = [],
		articles: [AIJobArticleInfo] = [],
		articleCount: Int? = nil,
		hasAPIKey: Bool = true,
		unreadOnly: Bool = false,
		coverage: AIJobCoverage? = nil,
		coverageQueryFailed: Bool = false,
		feedDisplayNames: [String: String] = [:],
		expanded: Set<AIJobFailureGroupKey> = [],
		retrying: Set<AIJobFailureGroupKey> = [],
		notices: [AIJobFailureGroupKey: String] = [:]
	) -> AIJobStatusInput {
		AIJobStatusInput(
			scope: scope,
			now: now,
			hasAPIKey: hasAPIKey,
			activeJobs: active,
			foldedFailures: foldedFailures,
			completedTodayJobs: completedToday,
			articlesByID: Dictionary(uniqueKeysWithValues: articles.map { ($0.articleID, $0) }),
			timelineArticleCount: articleCount ?? articles.count,
			unreadOnly: unreadOnly,
			coverage: coverage,
			coverageQueryFailed: coverageQueryFailed,
			feedDisplayNames: feedDisplayNames,
			expandedFailureGroups: expanded,
			retryingFailureGroups: retrying,
			failureRetryNotices: notices
		)
	}
}

// MARK: - Test doubles

@MainActor
private final class RecordingRetryEnqueuer: AIJobRetryEnqueuing {

	private(set) var requests: [AIJobRequeueRequest] = []
	var delay: Duration = .zero

	func enqueue(_ request: AIJobRequeueRequest) async -> Bool {
		requests.append(request)
		if delay > .zero {
			try? await Task.sleep(for: delay)
		}
		return true
	}
}

private final class NoCallClient: AIClient, @unchecked Sendable {

	func complete(messages: [AIMessage], temperature: Double?, maxTokens: Int?, thinking: AIThinkingMode?) async throws -> String {
		""
	}
}

private struct FixedResolver: AIArticleResolving {

	let article: AIArticle

	func article(for articleID: String) async -> AIArticle? {
		articleID == article.id ? article : nil
	}
}

private actor NoTaskLog: AITaskLogging {

	func recordTerminal(_ event: AITaskTerminalEvent) async {
	}

	func recordAttempt(_ event: AITaskAttemptEvent) async {
	}
}
