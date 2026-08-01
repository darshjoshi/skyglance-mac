import XCTest
@testable import SkyGlance

/// The decision that chooses between a popup and a notification.
///
/// This is the one piece of the popup feature where a silent mistake costs
/// someone their alerts entirely rather than degrading them, so it is pulled out
/// as a pure function specifically to be tested here — verifying it by hand
/// would mean switching VoiceOver on and waiting for a real aircraft.
final class AlertRoutingTests: XCTestCase {

    private func prefersPopup(enabled: Bool = true, present: Bool = true,
                              assistive: Bool = false, anchor: Bool = true) -> Bool {
        AlertRouting.prefersPopup(popupsEnabled: enabled,
                                  userIsPresent: present,
                                  assistiveTechInUse: assistive,
                                  menuBarAnchorAvailable: anchor)
    }

    func testPopupWhenEverythingIsAvailable() {
        XCTAssertTrue(prefersPopup())
    }

    /// The blocker. A card that never becomes key, announces nothing, and can
    /// only be paused with a mouse is not an alert for a VoiceOver or Switch
    /// Control user — and because it replaces the notification, they would get
    /// nothing at all.
    func testAssistiveTechFallsBackToTheNotification() {
        XCTAssertFalse(prefersPopup(assistive: true))
    }

    func testAssistiveTechWinsEvenWhenEverythingElseFavoursAPopup() {
        XCTAssertFalse(prefersPopup(enabled: true, present: true,
                                    assistive: true, anchor: true))
    }

    func testAwayFallsBackSoTheAlertWaitsInNotificationCenter() {
        XCTAssertFalse(prefersPopup(present: false))
    }

    func testTheToggleIsHonoured() {
        XCTAssertFalse(prefersPopup(enabled: false))
    }

    /// Checked as part of choosing the channel, not after. Deciding first and
    /// discovering later that the card could not be placed meant a real
    /// notification went out under the popup's looser budget.
    func testNoMenuBarAnchorFallsBack() {
        XCTAssertFalse(prefersPopup(anchor: false))
    }
}

final class UserPresenceTests: XCTestCase {

    func testPresentWhenRecentlyActiveAndUnlocked() {
        XCTAssertTrue(UserPresence.isPresent(idleSeconds: 5, screenLocked: false))
    }

    func testIdleCountsAsAway() {
        XCTAssertFalse(UserPresence.isPresent(idleSeconds: UserPresence.idleLimit + 1,
                                              screenLocked: false))
    }

    /// Locking is instantaneous, unlike the idle threshold — which is what makes
    /// the cross-channel duplicate reachable in the first place.
    func testLockedCountsAsAwayEvenWhenActiveASecondAgo() {
        XCTAssertFalse(UserPresence.isPresent(idleSeconds: 0, screenLocked: true))
    }
}

final class MenuBarAnchorTests: XCTestCase {

    private let size = CGSize(width: 300, height: 208)

    func testCardIsCentredUnderTheStatusItem() {
        let item = CGRect(x: 2000, y: 1410, width: 120, height: 30)
        let origin = MenuBarAnchor.popupOrigin(for: size, below: item)
        XCTAssertEqual(origin.x + size.width / 2, item.midX, accuracy: 0.5,
                       "the card must line up with the icon it came from")
    }

    func testCardHangsBelowTheStatusItem() {
        let item = CGRect(x: 2000, y: 1410, width: 120, height: 30)
        let origin = MenuBarAnchor.popupOrigin(for: size, below: item)
        // Screen coordinates are bottom-left origin, so "below" is a lower y,
        // and the card's top edge must clear the item's bottom edge.
        XCTAssertLessThanOrEqual(origin.y + size.height, item.minY)
    }

    /// A status item hard against the right edge must not push the card off it.
    func testCardIsPulledBackInsideTheScreen() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first).visibleFrame
        let item = CGRect(x: screen.maxX - 30, y: screen.maxY, width: 30, height: 30)
        let origin = MenuBarAnchor.popupOrigin(for: size, below: item)
        XCTAssertLessThanOrEqual(origin.x + size.width, screen.maxX,
                                 "the card must stay on screen")
    }
}
