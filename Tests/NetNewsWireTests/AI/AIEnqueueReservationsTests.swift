//
//  AIEnqueueReservationsTests.swift
//  NetNewsWireTests
//

import Foundation
import Testing

@testable import NetNewsWire

@Suite struct AIEnqueueReservationsTests {

	@Test func firstReservationWins() {
		var reservations = AIEnqueueReservations()

		#expect(reservations.reserve("bodyTranslation:a") == true)
		#expect(reservations.reserve("bodyTranslation:a") == false)
	}

	@Test func releasedReservationCanBeTakenAgain() {
		var reservations = AIEnqueueReservations()
		#expect(reservations.reserve("rewrite:a") == true)

		reservations.release("rewrite:a")

		#expect(reservations.contains("rewrite:a") == false)
		#expect(reservations.reserve("rewrite:a") == true)
	}

	@Test func removeAllDropsOnlyMatchingArticleIDs() {
		var reservations = AIEnqueueReservations()
		#expect(reservations.reserve("rewrite:keep") == true)
		#expect(reservations.reserve("rewrite:gone") == true)

		reservations.removeAll { key in
			key.hasSuffix(":gone")
		}

		#expect(reservations.contains("rewrite:keep"))
		#expect(reservations.contains("rewrite:gone") == false)
	}
}
