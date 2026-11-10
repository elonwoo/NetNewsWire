//
//  AIJobStatusView.swift
//  NetNewsWire
//

import AI
import AppKit

/// The right-pane task board shown when no article is selected. The scope
/// header stays pinned; everything else scrolls as one column: status, AI
/// coverage, attention and recent activity.
@MainActor
final class AIJobStatusView: NSView {

	var onToggleFailureGroup: ((AIJobFailureGroupKey) -> Void)?
	var onRetryFailureGroup: ((AIJobFailureGroupKey, [AIJobRequeueRequest]) -> Void)?
	var onOpenSettings: (() -> Void)?

	private let scopeIconView = NSImageView()
	private let scopeTitleLabel = NSTextField(labelWithString: "")
	private let scopeSubtitleLabel = NSTextField(labelWithString: "")
	private let headerView = NSView()
	private let scrollView = NSScrollView()
	private let documentView = AIFlippedView()
	private let contentStack = NSStackView()

	fileprivate static let wideLayoutThreshold: CGFloat = 440

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		setup()
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override var acceptsFirstResponder: Bool {
		false
	}

	override func viewDidChangeEffectiveAppearance() {
		super.viewDidChangeEffectiveAppearance()
		updateBackground()
	}

	func render(_ model: AIJobStatusViewModel) {
		let wasAtTop = scrollView.contentView.bounds.origin.y <= 1
		let savedOrigin = scrollView.contentView.bounds.origin

		scopeTitleLabel.stringValue = model.scopeTitle
		scopeSubtitleLabel.stringValue = model.scopeSubtitle
		scopeIconView.image = Self.icon(for: model.scopeKind)

		rebuildContent(model)
		layoutSubtreeIfNeeded()

		let targetOrigin = wasAtTop ? .zero : savedOrigin
		scrollView.contentView.scroll(to: targetOrigin)
		scrollView.reflectScrolledClipView(scrollView.contentView)
	}

	/// Drops the previous scope's content so a switch never shows stale counts
	/// while the new query is in flight.
	func clear() {
		scopeTitleLabel.stringValue = ""
		scopeSubtitleLabel.stringValue = ""
		scopeIconView.image = nil
		clearContent()
		scrollView.contentView.scroll(to: .zero)
		scrollView.reflectScrolledClipView(scrollView.contentView)
	}
}

// MARK: - Setup

private extension AIJobStatusView {

	func setup() {
		translatesAutoresizingMaskIntoConstraints = false
		wantsLayer = true
		updateBackground()

		headerView.translatesAutoresizingMaskIntoConstraints = false
		addSubview(headerView)

		scopeIconView.translatesAutoresizingMaskIntoConstraints = false
		scopeIconView.imageScaling = .scaleProportionallyDown
		scopeIconView.contentTintColor = .secondaryLabelColor
		headerView.addSubview(scopeIconView)

		scopeTitleLabel.translatesAutoresizingMaskIntoConstraints = false
		scopeTitleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
		scopeTitleLabel.lineBreakMode = .byTruncatingTail
		scopeTitleLabel.maximumNumberOfLines = 1
		scopeTitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		headerView.addSubview(scopeTitleLabel)

		scopeSubtitleLabel.translatesAutoresizingMaskIntoConstraints = false
		scopeSubtitleLabel.font = .systemFont(ofSize: 11)
		scopeSubtitleLabel.textColor = .secondaryLabelColor
		scopeSubtitleLabel.lineBreakMode = .byTruncatingTail
		scopeSubtitleLabel.maximumNumberOfLines = 1
		scopeSubtitleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
		headerView.addSubview(scopeSubtitleLabel)

		scrollView.translatesAutoresizingMaskIntoConstraints = false
		scrollView.hasVerticalScroller = true
		scrollView.autohidesScrollers = true
		scrollView.drawsBackground = false
		scrollView.borderType = .noBorder
		addSubview(scrollView)

		let headerSeparator = AIJobHairlineView()
		headerView.addSubview(headerSeparator)
		NSLayoutConstraint.activate([
			headerSeparator.leadingAnchor.constraint(equalTo: headerView.leadingAnchor),
			headerSeparator.trailingAnchor.constraint(equalTo: headerView.trailingAnchor),
			headerSeparator.bottomAnchor.constraint(equalTo: headerView.bottomAnchor),
			headerSeparator.heightAnchor.constraint(equalToConstant: 1)
		])

		documentView.translatesAutoresizingMaskIntoConstraints = false
		scrollView.documentView = documentView

		contentStack.translatesAutoresizingMaskIntoConstraints = false
		contentStack.orientation = .vertical
		contentStack.alignment = .leading
		contentStack.spacing = 14
		documentView.addSubview(contentStack)

		NSLayoutConstraint.activate([
			headerView.topAnchor.constraint(equalTo: topAnchor),
			headerView.leadingAnchor.constraint(equalTo: leadingAnchor),
			headerView.trailingAnchor.constraint(equalTo: trailingAnchor),

			scopeIconView.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 20),
			scopeIconView.widthAnchor.constraint(equalToConstant: 18),
			scopeIconView.heightAnchor.constraint(equalToConstant: 18),
			scopeIconView.centerYAnchor.constraint(equalTo: scopeTitleLabel.centerYAnchor),

			scopeTitleLabel.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 13),
			scopeTitleLabel.leadingAnchor.constraint(equalTo: scopeIconView.trailingAnchor, constant: 8),
			scopeTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: scopeSubtitleLabel.leadingAnchor, constant: -8),

			scopeSubtitleLabel.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -20),
			scopeSubtitleLabel.centerYAnchor.constraint(equalTo: scopeTitleLabel.centerYAnchor),

			headerView.bottomAnchor.constraint(equalTo: scopeTitleLabel.bottomAnchor, constant: 12),

			scrollView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
			scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
			scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
			scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

			documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
			documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
			documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
			documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

			contentStack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 14),
			contentStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 16),
			contentStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -16),
			contentStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -18)
		])
	}

	func updateBackground() {
		effectiveAppearance.performAsCurrentDrawingAppearance {
			layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
		}
	}
}

// MARK: - Rendering

private extension AIJobStatusView {

	func rebuildContent(_ model: AIJobStatusViewModel) {
		clearContent()

		if model.showsGatewayBanner {
			addFullWidth(makeGatewayBanner(), spacingAfter: 12)
		}

		addFullWidth(makeStatusZone(model), spacingAfter: 14)

		if let coverage = model.coverage {
			addFullWidth(makeCoverageZone(coverage, emptyMessage: model.coverageEmptyMessage), spacingAfter: 14)
		}

		if let anomalies = model.anomalies {
			addFullWidth(makeAnomalyZone(anomalies), spacingAfter: 14)
		}

		if let activity = model.activity {
			addFullWidth(makeActivityZone(activity), spacingAfter: 14)
		}

		for line in model.footerLines {
			addFullWidth(makeFootnote(line), spacingAfter: 4)
		}
	}

	func addFullWidth(_ view: NSView, spacingAfter: CGFloat? = nil) {
		contentStack.addArrangedSubview(view)
		view.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
		if let spacingAfter {
			contentStack.setCustomSpacing(spacingAfter, after: view)
		}
	}

	func clearContent() {
		for subview in contentStack.arrangedSubviews {
			contentStack.removeArrangedSubview(subview)
			subview.removeFromSuperview()
		}
	}

	// MARK: Status

	func makeStatusZone(_ model: AIJobStatusViewModel) -> NSView {
		let zone = NSStackView()
		zone.orientation = .vertical
		zone.alignment = .leading
		zone.spacing = 7
		zone.addArrangedSubview(makeZoneHeader("任务进度", trailing: "当前列表"))
		let card = makeStatusCard(model)
		zone.addArrangedSubview(card)
		for view in zone.arrangedSubviews {
			view.widthAnchor.constraint(equalTo: zone.widthAnchor).isActive = true
		}
		return zone
	}

	func makeStatusCard(_ model: AIJobStatusViewModel) -> NSView {
		let card = AIJobTintView(fillColor: .controlBackgroundColor, cornerRadius: 10)

		let dot = AIJobTintView(fillColor: Self.color(for: model.headline.tone), cornerRadius: 3.5)
		dot.translatesAutoresizingMaskIntoConstraints = false
		dot.widthAnchor.constraint(equalToConstant: 7).isActive = true
		dot.heightAnchor.constraint(equalToConstant: 7).isActive = true

		let headlineLabel = makeLabel(model.headline.text, font: .systemFont(ofSize: 14, weight: .semibold), color: Self.color(for: model.headline.tone))
		headlineLabel.lineBreakMode = .byTruncatingTail
		let headlineRow = NSStackView(views: [dot, headlineLabel, NSView()])
		headlineRow.orientation = .horizontal
		headlineRow.alignment = .centerY
		headlineRow.spacing = 8

		let stack = NSStackView()
		stack.orientation = .vertical
		stack.alignment = .leading
		stack.spacing = 0
		stack.translatesAutoresizingMaskIntoConstraints = false
		card.addSubview(stack)
		NSLayoutConstraint.activate([
			stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
			stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
			stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
			stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10)
		])

		stack.addArrangedSubview(headlineRow)
		stack.setCustomSpacing(10, after: headlineRow)
		headlineRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

		let topHairline = AIJobHairlineView()
		topHairline.heightAnchor.constraint(equalToConstant: 1).isActive = true
		stack.addArrangedSubview(topHairline)
		topHairline.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

		let tiles = makeTilesRow(model.tiles)
		stack.addArrangedSubview(tiles)
		tiles.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

		let bottomHairline = AIJobHairlineView()
		bottomHairline.heightAnchor.constraint(equalToConstant: 1).isActive = true
		stack.addArrangedSubview(bottomHairline)
		bottomHairline.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

		if !model.emptyStateLines.isEmpty {
			let hints = makeHintsStack(model.emptyStateLines)
			stack.addArrangedSubview(hints)
			hints.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
			stack.setCustomSpacing(8, after: bottomHairline)
			stack.setCustomSpacing(8, after: hints)
		}

		return card
	}

	func makeTilesRow(_ tiles: [AIJobTile]) -> NSView {
		let row = NSStackView()
		row.orientation = .horizontal
		row.alignment = .top
		row.distribution = .fillEqually
		row.spacing = 0
		for (index, tile) in tiles.enumerated() {
			row.addArrangedSubview(makeTileView(tile, showsLeadingSeparator: index > 0))
		}
		return row
	}

	func makeTileView(_ tile: AIJobTile, showsLeadingSeparator: Bool) -> NSView {
		let numberLabel = makeLabel("\(tile.count)", font: .monospacedDigitSystemFont(ofSize: 20, weight: .semibold), color: Self.tileNumberColor(tile))
		numberLabel.alignment = .center
		let titleLabel = makeLabel(tile.title, font: .systemFont(ofSize: 10.5), color: .secondaryLabelColor)
		titleLabel.alignment = .center

		let view = AIJobTileView(showsLeadingSeparator: showsLeadingSeparator)
		view.translatesAutoresizingMaskIntoConstraints = false
		for label in [numberLabel, titleLabel] {
			label.translatesAutoresizingMaskIntoConstraints = false
			view.addSubview(label)
		}
		NSLayoutConstraint.activate([
			numberLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
			numberLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
			numberLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 2),
			numberLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -2),
			titleLabel.topAnchor.constraint(equalTo: numberLabel.bottomAnchor, constant: 1),
			titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
			titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 2),
			titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -2),
			titleLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6)
		])
		return view
	}

	func makeHintsStack(_ lines: [String]) -> NSView {
		let stack = NSStackView()
		stack.orientation = .vertical
		stack.alignment = .leading
		stack.spacing = 4
		for (index, line) in lines.enumerated() {
			let dot = AIJobTintView(fillColor: index == 0 ? .controlAccentColor : .tertiaryLabelColor, cornerRadius: 2.5)
			dot.translatesAutoresizingMaskIntoConstraints = false
			dot.widthAnchor.constraint(equalToConstant: 5).isActive = true
			dot.heightAnchor.constraint(equalToConstant: 5).isActive = true
			let label = makeLabel(line, font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
			label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
			let row = NSStackView(views: [dot, label, NSView()])
			row.orientation = .horizontal
			row.alignment = .centerY
			row.spacing = 6
			stack.addArrangedSubview(row)
			row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
		}
		return stack
	}

	// MARK: Coverage

	func makeCoverageZone(_ coverage: AIJobCoverage, emptyMessage: String?) -> NSView {
		let zone = NSStackView()
		zone.orientation = .vertical
		zone.alignment = .leading
		zone.spacing = 7
		let trailing = coverage.rows.isEmpty ? nil : "\(coverage.feedCount) 个订阅源"
		zone.addArrangedSubview(makeZoneHeader("AI 覆盖", trailing: trailing))
		if coverage.rows.isEmpty {
			zone.addArrangedSubview(makeFootnote(emptyMessage ?? "列表内没有文章"))
		} else {
			zone.addArrangedSubview(AIJobCoverageTableView(coverage: coverage))
		}
		for view in zone.arrangedSubviews {
			view.widthAnchor.constraint(equalTo: zone.widthAnchor).isActive = true
		}
		return zone
	}

	// MARK: Anomalies

	func makeAnomalyZone(_ anomalies: AIJobAnomalySection) -> NSView {
		let zone = NSStackView()
		zone.orientation = .vertical
		zone.alignment = .leading
		zone.spacing = 7

		let titleLabel = makeLabel("需要留意", font: .systemFont(ofSize: 12, weight: .semibold), color: .systemRed)
		let pill = makeCountPill("\(anomalies.totalCount) 项")
		let header = NSStackView(views: [titleLabel, NSView(), pill])
		header.orientation = .horizontal
		header.alignment = .centerY
		header.spacing = 8
		zone.addArrangedSubview(header)

		for group in anomalies.groups {
			zone.addArrangedSubview(makeFailureCard(group))
		}
		for view in zone.arrangedSubviews {
			view.widthAnchor.constraint(equalTo: zone.widthAnchor).isActive = true
		}
		return zone
	}

	func makeCountPill(_ text: String) -> NSView {
		let pill = AIJobTintView(fillColor: NSColor.systemRed.withAlphaComponent(0.12), borderColor: NSColor.systemRed.withAlphaComponent(0.25), borderWidth: 1, cornerRadius: 8)
		let label = makeLabel(text, font: .monospacedDigitSystemFont(ofSize: 10, weight: .semibold), color: .systemRed)
		label.translatesAutoresizingMaskIntoConstraints = false
		pill.addSubview(label)
		NSLayoutConstraint.activate([
			label.topAnchor.constraint(equalTo: pill.topAnchor, constant: 1),
			label.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -1),
			label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 6),
			label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -6)
		])
		return pill
	}

	func makeFailureCard(_ group: AIJobFailureGroup) -> NSView {
		let card = AIJobTintView(
			fillColor: NSColor.systemRed.withAlphaComponent(0.07),
			borderColor: NSColor.systemRed.withAlphaComponent(0.2),
			borderWidth: 1,
			cornerRadius: 8
		)

		let warn = NSImageView()
		warn.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
		warn.contentTintColor = .systemRed
		warn.translatesAutoresizingMaskIntoConstraints = false
		warn.widthAnchor.constraint(equalToConstant: 15).isActive = true
		warn.heightAnchor.constraint(equalToConstant: 15).isActive = true

		let titleLabel = makeLabel(group.title, font: .systemFont(ofSize: 11.5, weight: .semibold), color: .systemRed)
		let reasonLabel = makeLabel(group.reason, font: .systemFont(ofSize: 10.5), color: .secondaryLabelColor)
		reasonLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		let textStack = NSStackView(views: [titleLabel, reasonLabel])
		textStack.orientation = .vertical
		textStack.alignment = .leading
		textStack.spacing = 1

		let chevron = NSImageView()
		chevron.image = NSImage(systemSymbolName: group.isExpanded ? "chevron.up" : "chevron.down", accessibilityDescription: nil)
		chevron.contentTintColor = .tertiaryLabelColor
		chevron.translatesAutoresizingMaskIntoConstraints = false

		let headerContent = NSStackView(views: [warn, textStack, NSView(), chevron])
		headerContent.orientation = .horizontal
		headerContent.alignment = .centerY
		headerContent.spacing = 7

		let headerRow = AIJobRowView()
		headerRow.translatesAutoresizingMaskIntoConstraints = false
		headerContent.translatesAutoresizingMaskIntoConstraints = false
		headerRow.addSubview(headerContent)
		NSLayoutConstraint.activate([
			headerContent.topAnchor.constraint(equalTo: headerRow.topAnchor, constant: 8),
			headerContent.leadingAnchor.constraint(equalTo: headerRow.leadingAnchor, constant: 10),
			headerContent.trailingAnchor.constraint(equalTo: headerRow.trailingAnchor, constant: -10),
			headerContent.bottomAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: -8)
		])
		headerRow.onClick = { [weak self] in
			self?.onToggleFailureGroup?(group.key)
		}
		headerRow.toolTip = group.isExpanded ? "收起原因" : "展开原因和涉及订阅源"

		let content = NSStackView()
		content.orientation = .vertical
		content.alignment = .leading
		content.spacing = 0
		content.translatesAutoresizingMaskIntoConstraints = false
		card.addSubview(content)
		NSLayoutConstraint.activate([
			content.topAnchor.constraint(equalTo: card.topAnchor),
			content.leadingAnchor.constraint(equalTo: card.leadingAnchor),
			content.trailingAnchor.constraint(equalTo: card.trailingAnchor),
			content.bottomAnchor.constraint(equalTo: card.bottomAnchor)
		])
		content.addArrangedSubview(headerRow)
		headerRow.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

		if group.isExpanded {
			content.addArrangedSubview(makeFailureBody(group))
		}
		return card
	}

	func makeFailureBody(_ group: AIJobFailureGroup) -> NSView {
		let reason = NSTextField(wrappingLabelWithString: group.reason)
		reason.font = .systemFont(ofSize: 11)
		reason.textColor = .secondaryLabelColor
		reason.maximumNumberOfLines = 4

		let feeds = NSTextField(wrappingLabelWithString: group.involvedFeedsText)
		feeds.font = .systemFont(ofSize: 10.5)
		feeds.textColor = .tertiaryLabelColor
		feeds.maximumNumberOfLines = 3

		let button = AIJobRetryButton(title: group.isRetrying ? "正在重试…" : "重试全部", target: self, action: #selector(retryClicked(_:)))
		button.groupKey = group.key
		button.requests = group.retryableJobs
		button.isEnabled = !group.isRetrying
		button.refusesFirstResponder = true
		button.bezelStyle = .rounded
		button.controlSize = .small
		button.font = .systemFont(ofSize: 10.5, weight: .semibold)
		button.attributedTitle = NSAttributedString(string: group.isRetrying ? "正在重试…" : "重试全部", attributes: [
			.font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
			.foregroundColor: NSColor.systemRed
		])

		let body = NSStackView(views: [reason, feeds, button])
		body.orientation = .vertical
		body.alignment = .leading
		body.spacing = 5
		if let notice = group.retryNotice {
			body.addArrangedSubview(makeFootnote(notice))
		}

		let spacer = NSView()
		spacer.translatesAutoresizingMaskIntoConstraints = false
		spacer.widthAnchor.constraint(equalToConstant: 22).isActive = true
		let row = NSStackView(views: [spacer, body])
		row.orientation = .horizontal
		row.alignment = .top
		row.spacing = 0
		row.edgeInsets = NSEdgeInsets(top: 2, left: 10, bottom: 10, right: 10)
		row.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		body.widthAnchor.constraint(equalTo: row.widthAnchor, constant: -42).isActive = true
		for view in body.arrangedSubviews {
			view.widthAnchor.constraint(lessThanOrEqualTo: body.widthAnchor).isActive = true
		}
		return row
	}

	// MARK: Activity

	func makeActivityZone(_ activity: AIJobActivitySection) -> NSView {
		let zone = NSStackView()
		zone.orientation = .vertical
		zone.alignment = .leading
		zone.spacing = 7
		zone.addArrangedSubview(makeZoneHeader("最近活动", trailing: activity.lastActivityText))

		let label = makeLabel("今日完成", font: .systemFont(ofSize: 10.5), color: .tertiaryLabelColor)
		label.translatesAutoresizingMaskIntoConstraints = false
		label.widthAnchor.constraint(equalToConstant: 52).isActive = true

		let items = makeLabel("", font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
		items.attributedStringValue = Self.activityText(activity.items)
		items.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		items.cell?.truncatesLastVisibleLine = true

		let total = makeLabel("共 \(activity.totalCount) 项", font: .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular), color: .tertiaryLabelColor)
		total.setContentHuggingPriority(.required, for: .horizontal)

		let row = NSStackView(views: [label, items, NSView(), total])
		row.orientation = .horizontal
		row.alignment = .centerY
		row.spacing = 10
		zone.addArrangedSubview(row)
		for view in zone.arrangedSubviews {
			view.widthAnchor.constraint(equalTo: zone.widthAnchor).isActive = true
		}
		return zone
	}

	// MARK: Shared

	func makeZoneHeader(_ title: String, trailing: String? = nil) -> NSView {
		let titleLabel = makeLabel(title, font: .systemFont(ofSize: 12, weight: .semibold), color: .labelColor)
		let row = NSStackView()
		row.orientation = .horizontal
		row.alignment = .firstBaseline
		row.spacing = 8
		row.addArrangedSubview(titleLabel)
		row.addArrangedSubview(NSView())
		if let trailing {
			row.addArrangedSubview(makeLabel(trailing, font: .systemFont(ofSize: 10.5), color: .tertiaryLabelColor))
		}
		return row
	}

	func makeGatewayBanner() -> NSView {
		let banner = AIJobTintView(fillColor: NSColor.systemRed.withAlphaComponent(0.08), cornerRadius: 8)

		let title = NSTextField(wrappingLabelWithString: "AI 网关没有配置，任务不会开始。")
		title.font = .systemFont(ofSize: 12)
		title.textColor = .labelColor

		let button = makeActionButton(title: "打开 AI 设置", action: #selector(settingsClicked(_:)))
		button.refusesFirstResponder = true

		let stack = NSStackView(views: [title, button])
		stack.orientation = .vertical
		stack.alignment = .leading
		stack.spacing = 6
		stack.translatesAutoresizingMaskIntoConstraints = false
		banner.addSubview(stack)
		NSLayoutConstraint.activate([
			stack.topAnchor.constraint(equalTo: banner.topAnchor, constant: 10),
			stack.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 10),
			stack.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -10),
			stack.bottomAnchor.constraint(equalTo: banner.bottomAnchor, constant: -10),
			title.widthAnchor.constraint(equalTo: stack.widthAnchor)
		])
		return banner
	}

	func makeFootnote(_ text: String) -> NSTextField {
		makeLabel(text, font: .systemFont(ofSize: 11), color: .tertiaryLabelColor)
	}

	func makeLabel(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
		let label = PassThroughLabel(labelWithString: text)
		label.font = font
		label.textColor = color
		label.lineBreakMode = .byTruncatingTail
		label.maximumNumberOfLines = 1
		label.isSelectable = false
		return label
	}

	func makeActionButton(title: String, action: Selector) -> AIJobActionButton {
		let button = AIJobActionButton(title: title, target: self, action: action)
		button.bezelStyle = .inline
		button.isBordered = false
		button.font = .systemFont(ofSize: 11)
		button.attributedTitle = NSAttributedString(string: title, attributes: [
			.foregroundColor: NSColor.controlAccentColor,
			.font: NSFont.systemFont(ofSize: 11)
		])
		button.refusesFirstResponder = true
		button.setContentHuggingPriority(.required, for: .horizontal)
		button.setContentCompressionResistancePriority(.required, for: .horizontal)
		return button
	}

	@objc func retryClicked(_ sender: AIJobRetryButton) {
		guard let key = sender.groupKey else {
			return
		}
		onRetryFailureGroup?(key, sender.requests)
	}

	@objc func settingsClicked(_ sender: Any?) {
		onOpenSettings?()
	}

	// MARK: Text and colours

	static func activityText(_ items: [AIJobActivityItem]) -> NSAttributedString {
		let text = NSMutableAttributedString()
		for (index, item) in items.enumerated() {
			if index > 0 {
				text.append(NSAttributedString(string: "    ", attributes: [
					.font: NSFont.systemFont(ofSize: 11)
				]))
			}
			text.append(NSAttributedString(string: "● ", attributes: [
				.font: NSFont.systemFont(ofSize: 7),
				.foregroundColor: color(for: item.kind)
			]))
			text.append(NSAttributedString(string: "\(AIJobStatusModel.kindLabel(item.kind)) \(item.count)", attributes: [
				.font: NSFont.systemFont(ofSize: 11),
				.foregroundColor: NSColor.secondaryLabelColor
			]))
		}
		return text
	}

	static func color(for kind: AIJobKind) -> NSColor {
		switch kind {
		case .bodyTranslation: return .systemTeal
		case .titleTranslation: return .controlAccentColor
		case .rewrite: return .systemPurple
		}
	}

	static func color(for tone: AIJobStatusTone) -> NSColor {
		switch tone {
		case .red: return .systemRed
		case .orange: return .systemOrange
		case .green: return .systemGreen
		case .yellow: return .systemYellow
		case .gray: return .secondaryLabelColor
		}
	}

	static func tileNumberColor(_ tile: AIJobTile) -> NSColor {
		guard tile.count > 0 else {
			return .tertiaryLabelColor
		}
		switch tile.tone {
		case .accent: return .controlAccentColor
		case .neutral: return .labelColor
		case .retry: return .systemOrange
		case .danger: return .systemRed
		}
	}

	static func icon(for kind: AIJobScopeKind) -> NSImage? {
		let symbolName: String
		switch kind {
		case .feed: symbolName = "dot.radiowaves.left.and.right"
		case .folder: symbolName = "folder"
		case .today: symbolName = "clock"
		case .allUnread: symbolName = "circle"
		case .starred: symbolName = "star.fill"
		}
		let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
		return NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
	}
}

// MARK: - Coverage table

private final class AIJobCoverageTableView: NSView {

	private let coverage: AIJobCoverage
	private let headerView = AIJobCoverageHeaderView()
	private var rowViews: [AIJobCoverageRowView] = []
	private var separators: [AIJobHairlineView] = []
	private var lastNarrow = false
	private var measuredHeight: CGFloat = 0

	init(coverage: AIJobCoverage) {
		self.coverage = coverage
		super.init(frame: .zero)
		translatesAutoresizingMaskIntoConstraints = false
		for _ in coverage.rows {
			rowViews.append(AIJobCoverageRowView())
		}
		for _ in 0..<(rowViews.count + 1) {
			separators.append(AIJobHairlineView())
		}
		addSubview(headerView)
		for (index, row) in rowViews.enumerated() {
			row.configure(coverage.rows[index])
			addSubview(row)
		}
		for separator in separators {
			addSubview(separator)
		}
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override var isFlipped: Bool {
		true
	}

	override var intrinsicContentSize: NSSize {
		let narrow = bounds.width > 0 && bounds.width < AIJobStatusView.wideLayoutThreshold
		return NSSize(width: NSView.noIntrinsicMetric, height: height(narrow: narrow))
	}

	override func layout() {
		super.layout()
		let narrow = bounds.width < AIJobStatusView.wideLayoutThreshold
		if narrow != lastNarrow {
			lastNarrow = narrow
			invalidateIntrinsicContentSize()
		}

		let width = bounds.width
		let headerHeight: CGFloat = narrow ? 0 : 20
		let rowHeight: CGFloat = narrow ? 50 : 34
		var y: CGFloat = 0

		headerView.isHidden = narrow
		headerView.frame = NSRect(x: 0, y: y, width: width, height: headerHeight)
		y += headerHeight

		if !narrow {
			separators[0].frame = NSRect(x: 0, y: y, width: width, height: 1)
			y += 1
		}

		for (index, row) in rowViews.enumerated() {
			row.frame = NSRect(x: 0, y: y, width: width, height: rowHeight)
			y += rowHeight
			if index < rowViews.count - 1 {
				separators[index + 1].frame = NSRect(x: 0, y: y, width: width, height: 1)
				y += 1
			}
		}

		if abs(measuredHeight - y) > 0.5 {
			measuredHeight = y
			invalidateIntrinsicContentSize()
		}
	}

	private func height(narrow: Bool) -> CGFloat {
		let rowCount = max(1, coverage.rows.count)
		let rowHeight: CGFloat = narrow ? 50 : 34
		let headerHeight: CGFloat = narrow ? 0 : 20
		let headerSeparator: CGFloat = narrow ? 0 : 1
		let interRowSeparators = CGFloat(max(0, rowCount - 1))
		return headerHeight + headerSeparator + CGFloat(rowCount) * rowHeight + interRowSeparators
	}
}

private final class AIJobCoverageHeaderView: NSView {

	private let nameLabel = AIJobStatusViewMake.label("订阅源", font: .systemFont(ofSize: 10), color: .tertiaryLabelColor)
	private let totalLabel = AIJobStatusViewMake.label("篇数", font: .systemFont(ofSize: 10), color: .tertiaryLabelColor)
	private let translatedLabel = AIJobStatusViewMake.label("", font: .systemFont(ofSize: 10), color: .tertiaryLabelColor)
	private let rewrittenLabel = AIJobStatusViewMake.label("", font: .systemFont(ofSize: 10), color: .tertiaryLabelColor)
	private let originalLabel = AIJobStatusViewMake.label("", font: .systemFont(ofSize: 10), color: .tertiaryLabelColor)

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		translatedLabel.attributedStringValue = AIJobStatusViewMake.metricText(dot: .systemTeal, text: "译文", font: .systemFont(ofSize: 10))
		rewrittenLabel.attributedStringValue = AIJobStatusViewMake.metricText(dot: .systemPurple, text: "改写", font: .systemFont(ofSize: 10))
		originalLabel.attributedStringValue = AIJobStatusViewMake.metricText(dot: .tertiaryLabelColor, text: "原文", font: .systemFont(ofSize: 10))
		for label in [nameLabel, totalLabel, translatedLabel, rewrittenLabel, originalLabel] {
			label.alignment = .right
			addSubview(label)
		}
		nameLabel.alignment = .left
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override var isFlipped: Bool {
		true
	}

	override func layout() {
		super.layout()
		let frames = AIJobCoverageLayout.frames(width: bounds.width)
		nameLabel.frame = NSRect(x: 0, y: 2, width: max(0, frames.total.minX - 9), height: 16)
		totalLabel.frame = NSRect(x: frames.total.minX, y: 2, width: frames.total.width, height: 16)
		translatedLabel.frame = NSRect(x: frames.translated.minX, y: 2, width: frames.translated.width, height: 16)
		rewrittenLabel.frame = NSRect(x: frames.rewritten.minX, y: 2, width: frames.rewritten.width, height: 16)
		originalLabel.frame = NSRect(x: frames.original.minX, y: 2, width: frames.original.width, height: 16)
	}
}

private final class AIJobCoverageRowView: NSView {

	private let nameLabel = AIJobStatusViewMake.label("", font: .systemFont(ofSize: 12.5, weight: .medium), color: .labelColor)
	private let totalLabel = AIJobStatusViewMake.label("", font: .monospacedDigitSystemFont(ofSize: 12, weight: .semibold), color: .labelColor)
	private let translatedLabel = AIJobStatusViewMake.label("", font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular), color: .labelColor)
	private let rewrittenLabel = AIJobStatusViewMake.label("", font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular), color: .labelColor)
	private let originalLabel = AIJobStatusViewMake.label("", font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular), color: .tertiaryLabelColor)
	private let translatedNarrowLabel = AIJobStatusViewMake.label("", font: .systemFont(ofSize: 11), color: .labelColor)
	private let rewrittenNarrowLabel = AIJobStatusViewMake.label("", font: .systemFont(ofSize: 11), color: .labelColor)
	private let originalNarrowLabel = AIJobStatusViewMake.label("", font: .systemFont(ofSize: 11), color: .tertiaryLabelColor)
	private let translationBar = AIJobProgressBarView(tint: .systemTeal)
	private let rewriteBar = AIJobProgressBarView(tint: .systemPurple)
	private var row: AIJobCoverageRow?

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		for label in [nameLabel, totalLabel, translatedLabel, rewrittenLabel, originalLabel, translatedNarrowLabel, rewrittenNarrowLabel, originalNarrowLabel] {
			addSubview(label)
		}
		nameLabel.lineBreakMode = .byTruncatingTail
		translatedLabel.alignment = .right
		rewrittenLabel.alignment = .right
		originalLabel.alignment = .right
		totalLabel.alignment = .right
		addSubview(translationBar)
		addSubview(rewriteBar)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override var isFlipped: Bool {
		true
	}

	func configure(_ row: AIJobCoverageRow) {
		self.row = row
		nameLabel.stringValue = row.feedName
		totalLabel.stringValue = "\(row.total)"
		translatedLabel.stringValue = "\(row.translated)"
		rewrittenLabel.stringValue = "\(row.rewritten)"
		originalLabel.stringValue = "\(row.original)"
		nameLabel.toolTip = row.feedName
		translationBar.progress = row.translationProgress
		rewriteBar.progress = row.rewriteProgress
		translationBar.toolTip = "译文覆盖率 \(Int((row.translationProgress * 100).rounded()))%"
		rewriteBar.toolTip = "改写覆盖率 \(Int((row.rewriteProgress * 100).rounded()))%"
	}

	override func layout() {
		super.layout()
		let narrow = bounds.width < AIJobStatusView.wideLayoutThreshold
		translatedLabel.isHidden = narrow
		rewrittenLabel.isHidden = narrow
		originalLabel.isHidden = narrow
		translatedNarrowLabel.isHidden = !narrow
		rewrittenNarrowLabel.isHidden = !narrow
		originalNarrowLabel.isHidden = !narrow

		if narrow {
			let total = row?.total ?? 0
			let barWidth = min(max(0, bounds.width - 54), 300)
			nameLabel.frame = NSRect(x: 0, y: 2, width: max(0, bounds.width - 54), height: 18)
			totalLabel.stringValue = "\(total) 篇"
			totalLabel.frame = NSRect(x: max(0, bounds.width - 54), y: 2, width: 54, height: 18)
			layoutNarrowMetrics()
			rewriteBar.frame = NSRect(x: 0, y: 38, width: barWidth, height: 4)
			translationBar.frame = NSRect(x: 0, y: 43, width: barWidth, height: 4)
		} else {
			let frames = AIJobCoverageLayout.frames(width: bounds.width)
			let barWidth = min(frames.total.minX - 9, 300)
			nameLabel.frame = NSRect(x: 0, y: 2, width: max(0, frames.total.minX - 9), height: 18)
			totalLabel.frame = NSRect(x: frames.total.minX, y: 2, width: frames.total.width, height: 18)
			translatedLabel.frame = NSRect(x: frames.translated.minX, y: 2, width: frames.translated.width, height: 18)
			rewrittenLabel.frame = NSRect(x: frames.rewritten.minX, y: 2, width: frames.rewritten.width, height: 18)
			originalLabel.frame = NSRect(x: frames.original.minX, y: 2, width: frames.original.width, height: 18)
			rewriteBar.frame = NSRect(x: 0, y: 22, width: barWidth, height: 4)
			translationBar.frame = NSRect(x: 0, y: 27, width: barWidth, height: 4)
		}
	}

	private func layoutNarrowMetrics() {
		let metrics: [(label: NSTextField, dot: NSColor, title: String, value: String)] = [
			(rewrittenNarrowLabel, .systemPurple, "改写", "\(row?.rewritten ?? 0)"),
			(translatedNarrowLabel, .systemTeal, "译文", "\(row?.translated ?? 0)"),
			(originalNarrowLabel, .tertiaryLabelColor, "原文", "\(row?.original ?? 0)")
		]
		var x: CGFloat = 0
		for metric in metrics {
			metric.label.attributedStringValue = AIJobStatusViewMake.metricText(
				dot: metric.dot,
				text: "\(metric.title) \(metric.value)",
				font: .systemFont(ofSize: 11),
				color: metric.dot == .tertiaryLabelColor ? .tertiaryLabelColor : .labelColor
			)
			metric.label.sizeToFit()
			metric.label.frame = NSRect(x: x, y: 21, width: metric.label.frame.width, height: 16)
			x += metric.label.frame.width + 14
		}
	}
}

private enum AIJobCoverageLayout {

	struct Frames {
		let total: NSRect
		let translated: NSRect
		let rewritten: NSRect
		let original: NSRect
	}

	static func frames(width: CGFloat) -> Frames {
		let totalWidth: CGFloat = 44
		let metricWidth: CGFloat = 38
		let originalWidth: CGFloat = 44
		let gap: CGFloat = 9
		let original = NSRect(x: width - originalWidth, y: 0, width: originalWidth, height: 0)
		let translated = NSRect(x: original.minX - gap - metricWidth, y: 0, width: metricWidth, height: 0)
		let rewritten = NSRect(x: translated.minX - gap - metricWidth, y: 0, width: metricWidth, height: 0)
		let total = NSRect(x: rewritten.minX - gap - totalWidth, y: 0, width: totalWidth, height: 0)
		return Frames(total: total, translated: translated, rewritten: rewritten, original: original)
	}
}

/// Small shared label factory for manual-layout coverage views.
@MainActor
private enum AIJobStatusViewMake {

	static func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
		let label = NSTextField(labelWithString: text)
		label.font = font
		label.textColor = color
		label.lineBreakMode = .byTruncatingTail
		label.maximumNumberOfLines = 1
		label.isSelectable = false
		return label
	}

	static func metricText(dot: NSColor, text: String, font: NSFont, color: NSColor = .labelColor) -> NSAttributedString {
		let result = NSMutableAttributedString(string: "● ", attributes: [
			.font: NSFont.systemFont(ofSize: max(5, font.pointSize - 3)),
			.foregroundColor: dot
		])
		result.append(NSAttributedString(string: text, attributes: [
			.font: font,
			.foregroundColor: color
		]))
		return result
	}
}

// MARK: - Small views

private final class PassThroughLabel: NSTextField {

	override func hitTest(_ point: NSPoint) -> NSView? {
		nil
	}
}

private final class AIJobActionButton: NSButton {
}

private final class AIJobRetryButton: NSButton {

	var groupKey: AIJobFailureGroupKey?
	var requests: [AIJobRequeueRequest] = []
}

private final class AIJobRowView: NSView {

	var onClick: (() -> Void)?

	override func hitTest(_ point: NSPoint) -> NSView? {
		guard let hit = super.hitTest(point) else {
			return nil
		}
		var view: NSView? = hit
		while let current = view {
			if current is NSButton {
				return current
			}
			view = current.superview
		}
		return self
	}

	override func mouseDown(with event: NSEvent) {
		if let onClick {
			onClick()
		} else {
			super.mouseDown(with: event)
		}
	}

	override func resetCursorRects() {
		if onClick != nil {
			addCursorRect(bounds, cursor: .pointingHand)
		}
	}
}

private final class AIJobTileView: NSView {

	private let showsLeadingSeparator: Bool

	init(showsLeadingSeparator: Bool) {
		self.showsLeadingSeparator = showsLeadingSeparator
		super.init(frame: .zero)
		translatesAutoresizingMaskIntoConstraints = false
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func draw(_ dirtyRect: NSRect) {
		guard showsLeadingSeparator else {
			return
		}
		NSColor.separatorColor.setFill()
		NSRect(x: 0, y: 4, width: 1, height: max(0, bounds.height - 8)).fill()
	}
}

private final class AIJobHairlineView: NSView {

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		translatesAutoresizingMaskIntoConstraints = false
		wantsLayer = true
		layer?.backgroundColor = NSColor.separatorColor.cgColor
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func viewDidChangeEffectiveAppearance() {
		super.viewDidChangeEffectiveAppearance()
		effectiveAppearance.performAsCurrentDrawingAppearance {
			layer?.backgroundColor = NSColor.separatorColor.cgColor
		}
	}
}

private final class AIJobProgressBarView: NSView {

	var progress: Double = 0 {
		didSet {
			needsDisplay = true
		}
	}
	private let tint: NSColor

	init(tint: NSColor) {
		self.tint = tint
		super.init(frame: .zero)
		translatesAutoresizingMaskIntoConstraints = false
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func draw(_ dirtyRect: NSRect) {
		let track = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
		NSColor.quaternaryLabelColor.withAlphaComponent(0.12).setFill()
		track.fill()

		guard progress > 0 else {
			return
		}
		let clamped = min(1, max(0, progress))
		let fillRect = NSRect(x: 0, y: 0, width: bounds.width * clamped, height: bounds.height)
		let fill = NSBezierPath(roundedRect: fillRect, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
		tint.setFill()
		fill.fill()
	}
}

private final class AIJobTintView: NSView {

	private let fillColor: NSColor
	private let borderColor: NSColor?
	private let borderWidth: CGFloat
	private let cornerRadius: CGFloat

	init(fillColor: NSColor, borderColor: NSColor? = nil, borderWidth: CGFloat = 0, cornerRadius: CGFloat = 0) {
		self.fillColor = fillColor
		self.borderColor = borderColor
		self.borderWidth = borderWidth
		self.cornerRadius = cornerRadius
		super.init(frame: .zero)
		translatesAutoresizingMaskIntoConstraints = false
		wantsLayer = true
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override var wantsUpdateLayer: Bool {
		true
	}

	override func updateLayer() {
		guard let layer else {
			return
		}
		effectiveAppearance.performAsCurrentDrawingAppearance {
			layer.backgroundColor = fillColor.cgColor
			layer.borderColor = borderColor?.cgColor ?? NSColor.clear.cgColor
			layer.borderWidth = borderWidth
			layer.cornerRadius = cornerRadius
		}
	}

	override func viewDidChangeEffectiveAppearance() {
		super.viewDidChangeEffectiveAppearance()
		needsDisplay = true
	}
}
