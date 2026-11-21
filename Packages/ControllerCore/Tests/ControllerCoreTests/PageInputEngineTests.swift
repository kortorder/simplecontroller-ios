import Foundation
import XCTest
@testable import ControllerCore

final class PageInputEngineTests: XCTestCase {
    private func fixture() throws -> ControllerProfile {
        var profile = try ControllerProfile(swipeMode: .controls)
        try profile.addPage(name: "Second"); try profile.addPage(name: "Third")
        return profile
    }
    func testNavigationTracksOnePreviousPageAndStartsAtSavedHome() throws {
        var profile = try fixture(); let pages = profile.pages.map(\.id)
        try profile.setHomePage(pages[1])
        var engine = try ProfileInputEngine(profile: profile)
        XCTAssertEqual(engine.currentPageID, pages[1]); XCTAssertNil(engine.previousPageID)
        XCTAssertTrue(try engine.navigate(.goTo(pages[2]), at: 0))
        XCTAssertEqual(engine.previousPageID, pages[1])
        XCTAssertTrue(try engine.navigate(.toggle(pages[2]), at: 0.1))
        XCTAssertEqual(engine.currentPageID, pages[1]); XCTAssertEqual(engine.previousPageID, pages[2])
        XCTAssertTrue(try engine.navigate(.back, at: 0.2)); XCTAssertEqual(engine.currentPageID, pages[2])
        XCTAssertTrue(try engine.navigate(.home, at: 0.3)); XCTAssertEqual(engine.currentPageID, pages[1])
        XCTAssertTrue(try engine.navigate(.toggle(pages[0]), at: 0.4)); XCTAssertEqual(engine.currentPageID, pages[0])
    }
    func testPageChangeCancelsEveryOwnerAndPendingWorkBeforeAdvancingTime() throws {
        var profile = try fixture(); let home = profile.homePageID, next = profile.pages[1].id
        let ordinary = ProfileControl(payload: "RT:1P1,WAIT_100,MOUSE_RIGHT_DOWN")
        let toggle = ProfileControl(actions: [.a], buttonBehavior: .init(holdToggle: true))
        let auto = ProfileControl(payload: "W", autoTapEnabled: true)
        let stick = ProfileControl(kind: .leftStick, stickBehavior: .init(autoCenter: false))
        let pad = ProfileControl(kind: .touchpad, touchpadBehavior: .init(clickMode: .toggle))
        let scroll = ProfileControl(payload: "SCROLL_MODE_TOGGLE")
        for control in [ordinary, toggle, auto, stick, pad, scroll] { try profile.addControl(control, toPage: home) }
        var engine = try ProfileInputEngine(profile: profile)
        try engine.begin(contact: 1, control: ordinary.id, at: 0)
        try engine.begin(contact: 2, control: toggle.id, at: 0)
        try engine.begin(contact: 3, control: auto.id, at: 0)
        try engine.begin(contact: 4, control: stick.id, position: .init(x: 1), at: 0)
        try engine.end(contact: 4, at: 0)
        try engine.beginTouchpad(contact: 5, control: pad.id, at: 0)
        try engine.activate(scroll.id, at: 0)
        _ = engine.drainPracticeEvents()
        XCTAssertTrue(try engine.selectPage(next, at: 0.9))
        XCTAssertEqual(engine.practiceState, .neutral); XCTAssertTrue(engine.latchedControls.isEmpty)
        XCTAssertTrue(engine.retainedSticks.isEmpty); XCTAssertTrue(engine.pendingTouchpadLocks.isEmpty)
        XCTAssertTrue(engine.lockedTouchpads.isEmpty); XCTAssertNil(engine.nextDeadline)
        XCTAssertEqual(engine.drainPracticeEvents().events.map(\.kind), [.keyUp(.w), .reset])
        try engine.tick(at: 10); try engine.end(contact: 1, at: 11)
        XCTAssertEqual(engine.practiceState, .neutral)
        XCTAssertTrue(try engine.selectPage(home, at: 12)); XCTAssertEqual(engine.practiceState, .neutral)
    }
    func testSameMissingAndHomeNoOpsDoNotReleaseExistingClaims() throws {
        var profile = try fixture(); let home = profile.homePageID
        let held = ProfileControl(payload: "MOUSE_LEFT_DOWN,X360A")
        let pending = ProfileControl(actions: [.b], buttonBehavior: .init(holdToggle: true))
        try profile.addControl(held, toPage: home); try profile.addControl(pending, toPage: home)
        var engine = try ProfileInputEngine(profile: profile)
        try engine.begin(contact: 1, control: held.id, at: 0); try engine.begin(contact: 2, control: pending.id, at: 0)
        let state = engine.practiceState, deadline = engine.nextDeadline
        _ = engine.drainPracticeEvents()
        for navigation in [ProfilePageNavigation.goTo(home), .goTo(UUID()), .toggle(UUID()), .home, .back] {
            XCTAssertFalse(try engine.navigate(navigation, at: 0.1))
            XCTAssertEqual(engine.practiceState, state); XCTAssertEqual(engine.nextDeadline, deadline)
            XCTAssertTrue(engine.drainPracticeEvents().events.isEmpty)
        }
        XCTAssertEqual(engine.capturedControl(for: 1), held.id)
    }
    func testHiddenControlsCannotBeginActivateOrReceiveHandoff() throws {
        var profile = try fixture(); let home = profile.homePageID, hidden = profile.pages[1].id
        let a = ProfileControl(actions: [.a]), b = ProfileControl(actions: [.b]), pad = ProfileControl(kind: .touchpad)
        let nav = ProfileControl(kind: .pageButton, pageNavigation: .home)
        try profile.addControl(a, toPage: home)
        for control in [b, pad, nav] { try profile.addControl(control, toPage: hidden) }
        var engine = try ProfileInputEngine(profile: profile)
        try engine.begin(contact: 1, control: a.id, at: 0)
        XCTAssertThrowsError(try engine.begin(contact: 2, control: b.id, at: 0))
        XCTAssertThrowsError(try engine.beginTouchpad(contact: 2, control: pad.id, at: 0))
        XCTAssertThrowsError(try engine.activate(nav.id, at: 0))
        XCTAssertThrowsError(try engine.transfer(contact: 1, to: b.id, at: 0))
        XCTAssertFalse(try engine.handoff(contact: 1, to: b.id, at: 0))
        XCTAssertEqual(engine.state.buttons, [.a]); XCTAssertEqual(engine.currentPageID, home)
        XCTAssertTrue(try engine.selectPage(hidden, at: 0.1))
        try engine.begin(contact: 3, control: b.id, at: 0.1)
        XCTAssertEqual(engine.state.buttons, [.b])
        XCTAssertThrowsError(try engine.begin(contact: 4, control: a.id, at: 0.1))
    }
    func testDirectPageButtonCancelsBeforeOverdueHoldAndAccessibilityReturnsHome() throws {
        var profile = try fixture(); let home = profile.homePageID, second = profile.pages[1].id
        let pending = ProfileControl(actions: [.y], buttonBehavior: .init(holdToggle: true))
        let go = ProfileControl(kind: .pageButton, pageNavigation: .goTo(second))
        let back = ProfileControl(kind: .pageButton, pageNavigation: .back)
        try profile.addControl(pending, toPage: home); try profile.addControl(go, toPage: home)
        try profile.addControl(back, toPage: second)
        var engine = try ProfileInputEngine(profile: profile)
        try engine.begin(contact: 1, control: pending.id, at: 0)
        try engine.begin(contact: 2, control: go.id, at: 0.7)
        XCTAssertEqual(engine.currentPageID, second); XCTAssertTrue(engine.latchedControls.isEmpty)
        XCTAssertTrue(engine.state.isNeutral); XCTAssertNil(engine.capturedControl(for: 2))
        try engine.activate(back.id, at: 0.8)
        XCTAssertEqual(engine.currentPageID, home); XCTAssertTrue(engine.state.isNeutral)
        try engine.tick(at: 4); XCTAssertTrue(engine.latchedControls.isEmpty)
    }
    func testPageButtonCannotBeEnteredOrLeftBySwipeInAnyMode() throws {
        for mode in ProfileSwipeMode.allCases {
            var profile = try fixture(); profile.swipeMode = mode
            let a = ProfileControl(actions: [.a]), nav = ProfileControl(kind: .pageButton, pageNavigation: .home)
            try profile.addControl(a, toPage: profile.homePageID); try profile.addControl(nav, toPage: profile.homePageID)
            var engine = try ProfileInputEngine(profile: profile)
            try engine.begin(contact: 1, control: a.id, at: 0)
            XCTAssertFalse(try engine.handoff(contact: 1, to: nav.id, at: 0.1))
            try engine.end(contact: 1, at: 0.2)
            try engine.begin(contact: 2, control: nav.id, at: 0.3)
            try engine.transfer(contact: 2, to: a.id, at: 0.4)
            XCTAssertEqual(engine.capturedControl(for: 2), nav.id); XCTAssertTrue(engine.state.isNeutral)
            var router = try ProfileSwipeRouter(profile: profile)
            try router.begin(contact: 2, control: nav.id, at: 0)
            XCTAssertEqual(try router.decision(contact: 2, hitControls: [a.id], at: 0), .moveCurrent)
        }
    }
    func testNoOpPageButtonIgnoresTurboAndDoesNotRepeatOrClearOtherOwner() throws {
        var profile = try fixture(); profile.turboEnabled = true
        let held = ProfileControl(kind: .leftStick)
        let nav = ProfileControl(kind: .pageButton, pageNavigation: .home)
        try profile.addControl(held, toPage: profile.homePageID); try profile.addControl(nav, toPage: profile.homePageID)
        var engine = try ProfileInputEngine(profile: profile)
        try engine.begin(contact: 1, control: held.id, position: .init(x: 0.7), at: 0)
        try engine.begin(contact: 2, control: nav.id, at: 0.1)
        try engine.begin(contact: 3, control: nav.id, at: 0.2)
        XCTAssertNil(engine.nextDeadline)
        try engine.tick(at: 2); XCTAssertEqual(engine.state.leftStick.x, 0.7)
        XCTAssertFalse(engine.outputControls.contains(nav.id)); XCTAssertEqual(engine.state.buttons, [])
    }
    func testReleaseAllPreservesRuntimePageButApplyingProfileReturnsToHome() throws {
        let profile = try fixture(); let second = profile.pages[1].id
        var engine = try ProfileInputEngine(profile: profile)
        XCTAssertTrue(try engine.selectPage(second, at: 0))
        engine.releaseAll()
        XCTAssertEqual(engine.currentPageID, second); XCTAssertEqual(engine.previousPageID, profile.homePageID)
        try engine.apply(profile: profile)
        XCTAssertEqual(engine.currentPageID, profile.homePageID); XCTAssertNil(engine.previousPageID)
        let encoded = try JSONEncoder().encode(profile)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(text.contains("currentPageID")); XCTAssertFalse(text.contains("previousPageID"))
    }
    func testVisibleGeometryKeepsOrientationOrderAndOnlyCurrentMembers() throws {
        var profile = try fixture(); let home = profile.homePageID, second = profile.pages[1].id
        let a = ProfileControl(actions: [.a]), b = ProfileControl(actions: [.b]), c = ProfileControl(actions: [.x])
        for control in [a, b, c] { try profile.addControl(control, toPage: home) }
        try profile.move(a.id, to: .init(x: 0.3, y: 0.3), orientation: .portrait)
        try profile.moveControl(b.id, toPage: second)
        XCTAssertEqual(profile.placements(for: .portrait, on: home).map(\.id), [c.id, a.id])
        XCTAssertEqual(profile.placements(for: .landscape, on: home).map(\.id), [a.id, c.id])
        var engine = try ProfileInputEngine(profile: profile)
        XCTAssertEqual(engine.visibleControlIDs, [a.id, c.id])
        XCTAssertTrue(try engine.selectPage(second, at: 0)); XCTAssertEqual(engine.visibleControlIDs, [b.id])
    }
    func testInvalidNavigationTimeAndInvalidProfileApplyPreservePageAndClaims() throws {
        var profile = try fixture(); let control = ProfileControl(actions: [.a])
        try profile.addControl(control, toPage: profile.homePageID)
        var engine = try ProfileInputEngine(profile: profile)
        try engine.begin(contact: 1, control: control.id, at: 1)
        for time in [0.9, .nan, .infinity] { XCTAssertThrowsError(try engine.selectPage(profile.pages[1].id, at: time)) }
        var invalid = profile; invalid.pages[0].controlIDs = []
        XCTAssertThrowsError(try engine.apply(profile: invalid))
        XCTAssertEqual(engine.currentPageID, profile.homePageID); XCTAssertEqual(engine.state.buttons, [.a])
    }
}
