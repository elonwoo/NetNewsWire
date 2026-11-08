//
//  AIAppDefaultsTests.swift
//  NetNewsWireTests
//

import Foundation
import Testing

@testable import NetNewsWire

@Suite struct AIAppDefaultsTests {

	@Test func autoRewriteDefaultsToOn() {
		let key = AppDefaults.Key.aiAutoRewriteEnabled
		UserDefaults.standard.removeObject(forKey: key)
		defer {
			UserDefaults.standard.removeObject(forKey: key)
		}

		#expect(AppDefaults.aiAutoRewriteEnabled)

		AppDefaults.aiAutoRewriteEnabled = false
		#expect(!AppDefaults.aiAutoRewriteEnabled)

		AppDefaults.aiAutoRewriteEnabled = true
		#expect(AppDefaults.aiAutoRewriteEnabled)
	}
}
