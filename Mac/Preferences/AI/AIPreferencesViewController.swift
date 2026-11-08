//
//  AIPreferencesViewController.swift
//  NetNewsWire
//

import AppKit

/// Preferences pane for the local AI gateway: where requests go, which model
/// they use, and the API key that authenticates them.
final class AIPreferencesViewController: NSViewController {

	private static let preferredWidth: CGFloat = 512
	private static let preferredHeight: CGFloat = 320

	private let baseURLField = NSTextField()
	private let modelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
	private let fetchModelsButton = NSButton(title: AILocalization.string("Fetch Models"), target: nil, action: nil)
	private let apiKeyField = NSSecureTextField()
	private let statusLabel = NSTextField(labelWithString: "")
	private let messageLabel = NSTextField(wrappingLabelWithString: "")

	init() {
		super.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func loadView() {
		let rootView = NSView(frame: NSRect(x: 0, y: 0, width: Self.preferredWidth, height: Self.preferredHeight))
		view = rootView

		let title = NSTextField(labelWithString: AILocalization.string("AI Gateway"))
		title.font = .systemFont(ofSize: 15, weight: .semibold)

		let intro = NSTextField(wrappingLabelWithString: AILocalization.string("Translation, rewriting, and chat all go through the local gateway. Enter the gateway address and API key, then choose a model with Fetch Models."))
		intro.font = .systemFont(ofSize: 12)
		intro.textColor = .secondaryLabelColor

		configureEditable(baseURLField, placeholder: "http://127.0.0.1:3425/v1")

		modelPopup.font = .systemFont(ofSize: 13)
		modelPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
		modelPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true

		fetchModelsButton.target = self
		fetchModelsButton.action = #selector(fetchModels)
		fetchModelsButton.bezelStyle = .rounded
		fetchModelsButton.setContentHuggingPriority(.required, for: .horizontal)
		fetchModelsButton.setContentCompressionResistancePriority(.required, for: .horizontal)

		let modelRow = NSStackView(views: [modelPopup, fetchModelsButton])
		modelRow.orientation = .horizontal
		modelRow.alignment = .centerY
		modelRow.spacing = 8

		apiKeyField.placeholderString = AILocalization.string("Gateway API Key")
		apiKeyField.font = .systemFont(ofSize: 13)
		apiKeyField.setContentHuggingPriority(.defaultLow, for: .horizontal)
		apiKeyField.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true

		statusLabel.font = .systemFont(ofSize: 12)
		statusLabel.setContentHuggingPriority(.required, for: .horizontal)
		statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

		let keyRow = NSStackView(views: [apiKeyField, statusLabel])
		keyRow.orientation = .horizontal
		keyRow.alignment = .centerY
		keyRow.spacing = 10

		let grid = NSGridView(views: [
			[makeRowLabel(AILocalization.string("Gateway Address")), baseURLField],
			[makeRowLabel("API key"), keyRow],
			[makeRowLabel(AILocalization.string("Model")), modelRow]
		])
		grid.rowSpacing = 8
		grid.columnSpacing = 12
		grid.column(at: 0).xPlacement = .trailing
		grid.column(at: 1).width = 340

		let separator = NSBox()
		separator.boxType = .separator

		let saveButton = NSButton(title: AILocalization.string("Save"), target: self, action: #selector(saveAPIKey))
		saveButton.bezelStyle = .rounded
		saveButton.keyEquivalent = "\r"

		let clearButton = NSButton(title: AILocalization.string("Clear"), target: self, action: #selector(clearAPIKey))
		clearButton.bezelStyle = .rounded

		let buttonRow = NSStackView(views: [saveButton, clearButton])
		buttonRow.orientation = .horizontal
		buttonRow.alignment = .centerY
		buttonRow.spacing = 8
		buttonRow.translatesAutoresizingMaskIntoConstraints = false

		messageLabel.font = .systemFont(ofSize: 12)
		messageLabel.textColor = .secondaryLabelColor
		messageLabel.maximumNumberOfLines = 2

		let stack = NSStackView(views: [title, intro, separator, grid])
		stack.orientation = .vertical
		stack.alignment = .leading
		stack.spacing = 10
		stack.translatesAutoresizingMaskIntoConstraints = false

		messageLabel.translatesAutoresizingMaskIntoConstraints = false
		rootView.addSubview(stack)
		rootView.addSubview(messageLabel)
		rootView.addSubview(buttonRow)

		NSLayoutConstraint.activate([
			stack.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 20),
			stack.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 20),
			stack.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -20),
			intro.widthAnchor.constraint(equalTo: stack.widthAnchor),
			separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
			grid.widthAnchor.constraint(equalTo: stack.widthAnchor),

			messageLabel.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 12),
			messageLabel.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 20),
			messageLabel.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -20),

			buttonRow.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),
			buttonRow.topAnchor.constraint(greaterThanOrEqualTo: messageLabel.bottomAnchor, constant: 12),
			buttonRow.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -20)
		])

		updateStatus()
	}

	override func viewWillAppear() {
		super.viewWillAppear()
		let config = AIEnvironment.shared.config
		baseURLField.stringValue = config.baseURL.absoluteString
		populateModels([config.model], selecting: config.model)
		apiKeyField.stringValue = ""
		messageLabel.stringValue = ""
		updateStatus()
	}
}

// MARK: - Actions

private extension AIPreferencesViewController {

	@objc func saveAPIKey() {
		guard let baseURL = enteredBaseURL() else {
			showMessage(AILocalization.string("The gateway address is invalid. It must start with http:// or https://."), isError: true)
			return
		}

		let model = modelPopup.titleOfSelectedItem?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		guard !model.isEmpty else {
			showMessage(AILocalization.string("Fetch and select a model first."), isError: true)
			return
		}

		let apiKey = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

		do {
			try AIEnvironment.shared.updateGateway(baseURL: baseURL, model: model, apiKey: apiKey.isEmpty ? nil : apiKey)
			apiKeyField.stringValue = ""
			messageLabel.stringValue = ""
			updateStatus()
		} catch {
			showMessage(AILocalization.format("Save failed: %@", error.localizedDescription), isError: true)
		}
	}

	@objc func clearAPIKey() {
		do {
			try AIEnvironment.shared.updateAPIKey("")
			apiKeyField.stringValue = ""
			messageLabel.stringValue = ""
			updateStatus()
		} catch {
			showMessage(AILocalization.format("Clear failed: %@", error.localizedDescription), isError: true)
		}
	}

	@objc func fetchModels() {
		guard let baseURL = enteredBaseURL() else {
			showMessage(AILocalization.string("The gateway address is invalid. It must start with http:// or https://."), isError: true)
			return
		}

		let apiKey = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
		fetchModelsButton.isEnabled = false
		showMessage(AILocalization.string("Fetching models…"), isError: false)

		Task { @MainActor in
			defer {
				self.fetchModelsButton.isEnabled = true
			}
			do {
				let models = try await AIEnvironment.shared.fetchModelList(baseURL: baseURL, apiKey: apiKey.isEmpty ? nil : apiKey)
				guard !models.isEmpty else {
					self.showMessage(AILocalization.string("The gateway returned no models."), isError: true)
					return
				}
				self.populateModels(models, selecting: self.modelPopup.titleOfSelectedItem)
				self.showMessage(AILocalization.format("Fetched %lld models.", models.count), isError: false)
			} catch {
				self.showMessage(AILocalization.format("Fetch failed: %@", error.localizedDescription), isError: true)
			}
		}
	}
}

// MARK: - Helpers

private extension AIPreferencesViewController {

	func enteredBaseURL() -> URL? {
		let string = baseURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
		guard let url = URL(string: string),
			  let scheme = url.scheme?.lowercased(),
			  scheme == "http" || scheme == "https",
			  url.host?.isEmpty == false else {
			return nil
		}
		return url
	}

	func populateModels(_ models: [String], selecting current: String?) {
		let previous = current ?? AIEnvironment.shared.config.model
		var titles = models
		if !previous.isEmpty && !titles.contains(previous) {
			titles.insert(previous, at: 0)
		}
		modelPopup.removeAllItems()
		modelPopup.addItems(withTitles: titles)
		if !previous.isEmpty {
			modelPopup.selectItem(withTitle: previous)
		}
	}

	func makeRowLabel(_ text: String) -> NSTextField {
		let label = NSTextField(labelWithString: text)
		label.font = .systemFont(ofSize: 13)
		return label
	}

	func configureEditable(_ field: NSTextField, placeholder: String) {
		field.placeholderString = placeholder
		field.font = .systemFont(ofSize: 13)
		field.isEditable = true
		field.isSelectable = true
		field.isBezeled = true
		field.bezelStyle = .roundedBezel
		field.setContentHuggingPriority(.defaultLow, for: .horizontal)
		field.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
	}

	func updateStatus() {
		if AIEnvironment.shared.hasAPIKey {
			statusLabel.stringValue = AILocalization.string("Configured")
			statusLabel.textColor = .systemGreen
			// The stored key never goes back into the field, so the placeholder
			// carries the masked hint instead. Typing replaces it on save.
			apiKeyField.placeholderString = AILocalization.string("•••••••••••• (Saved)")
		} else {
			statusLabel.stringValue = AILocalization.string("Not Configured")
			statusLabel.textColor = .secondaryLabelColor
			apiKeyField.placeholderString = AILocalization.string("Gateway API Key")
		}
	}

	func showMessage(_ message: String, isError: Bool) {
		messageLabel.stringValue = message
		messageLabel.textColor = isError ? .systemRed : .secondaryLabelColor
	}
}
