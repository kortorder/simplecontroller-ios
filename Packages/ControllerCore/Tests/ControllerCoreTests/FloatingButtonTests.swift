import Foundation
import XCTest
@testable import ControllerCore

final class FloatingButtonTests: XCTestCase {
    private struct Fixture {
        let a = UUID(), b = UUID(), zoneID = UUID()
        var frames: [UUID: FloatingRect] { [a: .init(x: 40, y: 100, width: 60, height: 60),
                                          b: .init(x: 130, y: 100, width: 60, height: 60)] }
        var zone: FloatingButtonZone {
            let geometry = [a, b].map { FloatingMemberGeometry(id: $0, frame: frames[$0]!) }
            return .init(id: zoneID, name: "Group", kind: .buttonGroup, memberIDs: [a, b], startMemberID: a, groupSwipe: true,
                         portraitGeometry: .init(canvasWidth: 500, canvasHeight: 700,
                                                 zone: .init(x: 0, y: 0, width: 500, height: 700)),
                         portraitMembers: geometry, portraitRestoration: geometry)
        }
        var routing: FloatingButtonRouting { .init(transferableMembers: [a, b], entryEnabledMembers: [a, b]) }
    }
    private let canvas = FloatingRect(x: 0, y: 0, width: 500, height: 700)
    private func session(_ f: Fixture, zone: FloatingButtonZone? = nil,
                         routing: FloatingButtonRouting? = nil, touch: FloatingPoint = .init(x: 250, y: 300)) throws -> FloatingButtonSession {
        try .init(zone: zone ?? f.zone, orientation: .portrait, canonicalGeometry: f.frames,
                  touch: touch, usable: canvas, routing: routing ?? f.routing)
    }
    private func center(_ session: FloatingButtonSession, _ id: UUID) -> FloatingPoint {
        session.placement.members.first { $0.id == id }!.frame.center
    }

    func testPlacementTranslatesWithoutScalingTargetsOrSpacing() throws {
        let f = Fixture(); let original = f.zone
        let value = try session(f)
        XCTAssertEqual(value.placement.bounds.width, 150)
        XCTAssertEqual(value.placement.bounds.height, 108)
        XCTAssertEqual(value.placement.finish.height, 48)
        XCTAssertTrue(canvas.contains(value.placement.bounds))
        XCTAssertEqual(value.placement.members.map { $0.frame.width }, [60, 60])
        XCTAssertEqual(center(value, f.b).x - center(value, f.a).x, 90)
        XCTAssertEqual(center(value, f.a), .init(x: 250, y: 300))
        XCTAssertEqual(f.zone, original)
    }

    func testInsufficientSpaceIncludingFinishIsRefused() throws {
        let f = Fixture()
        XCTAssertThrowsError(try FloatingButtonSession(zone: f.zone, orientation: .portrait, canonicalGeometry: f.frames,
                                                       touch: .init(x: 50, y: 50), usable: .init(x: 0, y: 0, width: 149, height: 700), routing: f.routing))
        XCTAssertThrowsError(try FloatingButtonSession(zone: f.zone, orientation: .portrait, canonicalGeometry: f.frames,
                                                       touch: .init(x: 50, y: 50), usable: .init(x: 0, y: 0, width: 500, height: 107), routing: f.routing))
    }

    func testActivationScalesButOtherOrientationMembersDoNot() throws {
        let f = Fixture(); let zone = f.zone
        let active = try zone.portraitGeometry!.resolved(canvasWidth: 700, canvasHeight: 500)
        XCTAssertEqual(active, .init(x: 0, y: 0, width: 700, height: 500))
        let fallback = try zone.resolvedMembers(for: .landscape, canonical: [:])
        XCTAssertEqual(fallback, zone.portraitMembers)
        XCTAssertEqual(zone.portraitRestoration, zone.portraitMembers)
    }

    func testClampedSummonStillStartsAtChosenMemberCenter() throws {
        let f = Fixture(); var value = try session(f, touch: .init(x: 2, y: 2))
        var events: [FloatingButtonCommand] = []
        XCTAssertTrue(value.beginActivation(contact: 1, sessionID: value.sessionID) { events.append($0); return true })
        XCTAssertEqual(events, [.begin(member: f.a, contact: 1, sample: .init(x: 30, y: 30, width: 60, height: 60))])
        XCTAssertTrue(value.placement.finish.contains(.init(x: 2, y: 2)))
        XCTAssertEqual(value.placement.bounds.x, 0); XCTAssertEqual(value.placement.bounds.y, 0)
    }

    func testInitiallyInsideFinishRequiresExitThenReentry() throws {
        let f = Fixture(); var value = try session(f, touch: .init(x: 2, y: 2))
        _ = value.beginActivation(contact: 1, sessionID: value.sessionID) { _ in true }
        var events: [FloatingButtonCommand] = []
        _ = try value.move(contact: 1, through: [.init(x: 2, y: 20)], sessionID: value.sessionID) { events.append($0); return true }
        XCTAssertFalse(value.isFinished)
        events.removeAll()
        _ = try value.move(contact: 1, through: [.init(x: 2, y: 80), .init(x: 2, y: 20)], sessionID: value.sessionID) { events.append($0); return true }
        XCTAssertTrue(value.isFinished)
        XCTAssertEqual(events, [.finishScope(memberIDs: [f.a, f.b])])
    }

    func testRevealOnlyContactNeverStartsMemberByMovingAcrossIt() throws {
        let f = Fixture(); var zone = f.zone; zone.startMemberID = nil
        var value = try session(f, zone: zone); var events: [FloatingButtonCommand] = []
        _ = value.beginActivation(contact: 1, sessionID: value.sessionID) { events.append($0); return true }
        _ = try value.move(contact: 1, through: [center(value, f.a), center(value, f.b)], sessionID: value.sessionID) { events.append($0); return true }
        _ = try value.end(contact: 1, sessionID: value.sessionID) { events.append($0); return true }
        XCTAssertTrue(events.isEmpty); XCTAssertNil(value.capturedMemberID)
        XCTAssertTrue(value.begin(contact: 2, at: center(value, f.b), sessionID: value.sessionID) { events.append($0); return true })
        XCTAssertEqual(value.capturedMemberID, f.b)
        XCTAssertEqual(events.count, 1)
    }

    func testGroupHandoffUsesAcceptanceAndHasNoGlobalCooldown() throws {
        let f = Fixture(); var value = try session(f)
        _ = value.beginActivation(contact: 1, sessionID: value.sessionID) { _ in true }
        var events: [FloatingButtonCommand] = []
        _ = try value.move(contact: 1, through: [center(value, f.b), center(value, f.a)], sessionID: value.sessionID) { events.append($0); return true }
        let targets = events.compactMap { command -> UUID? in if case .handoff(_, _, let to, _, _) = command { to } else { nil } }
        XCTAssertEqual(targets, [f.b, f.a]); XCTAssertEqual(value.capturedMemberID, f.a)
    }

    func testRejectedHandoffKeepsSourceOwnershipAndSamples() throws {
        let f = Fixture(); var value = try session(f)
        _ = value.beginActivation(contact: 1, sessionID: value.sessionID) { _ in true }
        var events: [FloatingButtonCommand] = []
        _ = try value.move(contact: 1, through: [center(value, f.b)], sessionID: value.sessionID) {
            events.append($0); if case .handoff = $0 { return false }; return true
        }
        XCTAssertEqual(value.capturedMemberID, f.a)
        guard case .move(let member, _, _) = events.last! else { return XCTFail("Expected current source MOVE") }
        XCTAssertEqual(member, f.a)
    }

    func testDisabledEntryStillAllowsDirectTouchAndOutgoingSlide() throws {
        let f = Fixture()
        var value = try session(f, routing: .init(transferableMembers: [f.a, f.b], entryEnabledMembers: [f.b]))
        _ = value.beginActivation(contact: 1, sessionID: value.sessionID) { _ in true }
        XCTAssertEqual(value.capturedMemberID, f.a)
        _ = try value.move(contact: 1, through: [center(value, f.b)], sessionID: value.sessionID) { _ in true }
        XCTAssertEqual(value.capturedMemberID, f.b)
        _ = try value.move(contact: 1, through: [center(value, f.a)], sessionID: value.sessionID) { _ in true }
        XCTAssertEqual(value.capturedMemberID, f.b)
        _ = try value.end(contact: 1, sessionID: value.sessionID) { _ in true }
        _ = value.begin(contact: 2, at: center(value, f.a), sessionID: value.sessionID) { _ in true }
        XCTAssertEqual(value.capturedMemberID, f.a)
    }

    func testAdvancedMembersStayCapturedAndReceiveWholePath() throws {
        let f = Fixture()
        var value = try session(f, routing: .init(transferableMembers: [f.b], entryEnabledMembers: [f.b]))
        _ = value.beginActivation(contact: 1, sessionID: value.sessionID) { _ in true }
        var events: [FloatingButtonCommand] = []
        _ = try value.move(contact: 1, through: [center(value, f.b), center(value, f.a)], sessionID: value.sessionID) { events.append($0); return true }
        XCTAssertEqual(value.capturedMemberID, f.a); XCTAssertEqual(events.count, 1)
        guard case .move(_, _, let samples) = events[0] else { return XCTFail("Expected captured path") }
        XCTAssertEqual(samples.count, 2)
    }

    func testGapRetainsSourceRatherThanReleasingIt() throws {
        let f = Fixture(); var value = try session(f)
        _ = value.beginActivation(contact: 1, sessionID: value.sessionID) { _ in true }
        var events: [FloatingButtonCommand] = []
        _ = try value.move(contact: 1, through: [.init(x: 500, y: 600)], sessionID: value.sessionID) { events.append($0); return true }
        XCTAssertEqual(value.capturedMemberID, f.a)
        guard case .move(let member, _, _) = events.first! else { return XCTFail("Expected outside MOVE") }
        XCTAssertEqual(member, f.a)
    }

    func testOverlapUsesLastEligibleMemberInsteadOfCurrentPriority() throws {
        let f = Fixture(); var zone = f.zone
        zone.portraitMembers[1].frame.x = 60
        var value = try session(f, zone: zone)
        _ = value.beginActivation(contact: 1, sessionID: value.sessionID) { _ in true }
        _ = try value.move(contact: 1, through: [center(value, f.a)], sessionID: value.sessionID) { _ in true }
        XCTAssertEqual(value.capturedMemberID, f.b)
    }

    func testFinishIgnoringSwipesKeepsGroupOpenUntilFreshFinish() throws {
        let f = Fixture(); var zone = f.zone; zone.finishIgnoresSwipes = true
        var value = try session(f,zone:zone)
        _ = value.beginActivation(contact:1,sessionID:value.sessionID) { _ in true }
        let path = [value.placement.finish.center, center(value,f.b)]
        _ = try value.end(contact:1,through:path,sessionID:value.sessionID) { _ in true }
        XCTAssertFalse(value.isFinished)
        _ = value.finish(sessionID:value.sessionID) { _ in true }
        XCTAssertTrue(value.isFinished)
    }

    func testFinishCrossingWinsBeforeAllMovesAndHandoffs() throws {
        let f = Fixture(); var value = try session(f)
        _ = value.beginActivation(contact: 1, sessionID: value.sessionID) { _ in true }
        var events: [FloatingButtonCommand] = []
        let path = [center(value, f.b), value.placement.finish.center, center(value, f.a)]
        _ = try value.move(contact: 1, through: path, sessionID: value.sessionID) { events.append($0); return true }
        XCTAssertEqual(events, [.finishScope(memberIDs: [f.a, f.b])])
        XCTAssertTrue(value.isFinished)
    }

    func testTerminalCoalescedPathIsOneEndWithoutSyntheticMoves() throws {
        let f = Fixture(); var value = try session(f)
        _ = value.beginActivation(contact: 1, sessionID: value.sessionID) { _ in true }
        var events: [FloatingButtonCommand] = []
        _ = try value.end(contact: 1, through: [center(value, f.a), center(value, f.b)], sessionID: value.sessionID) { events.append($0); return true }
        XCTAssertEqual(events.count, 1)
        guard case .end(let member, _, let samples) = events[0] else { return XCTFail("Expected terminal END only") }
        XCTAssertEqual(member, f.a); XCTAssertEqual(samples.count, 2)
        XCTAssertNil(value.activeContact); XCTAssertFalse(value.isFinished)
    }

    func testMalformedBatchHasNoPartialDispatchOrMutation() throws {
        let f = Fixture(); var value = try session(f)
        _ = value.beginActivation(contact: 1, sessionID: value.sessionID) { _ in true }
        var events: [FloatingButtonCommand] = []
        XCTAssertThrowsError(try value.move(contact: 1, through: [center(value, f.b), .init(x: .nan, y: 0)], sessionID: value.sessionID) { events.append($0); return true })
        XCTAssertTrue(events.isEmpty); XCTAssertEqual(value.capturedMemberID, f.a)
        XCTAssertThrowsError(try value.end(contact: 1, through: Array(repeating: center(value, f.a), count: 257), sessionID: value.sessionID) { events.append($0); return true })
        XCTAssertTrue(events.isEmpty); XCTAssertEqual(value.activeContact, 1)
    }

    func testStaleSessionAndDifferentContactCannotAct() throws {
        let f = Fixture(); var value = try session(f); var events: [FloatingButtonCommand] = []
        XCTAssertFalse(value.beginActivation(contact: 1, sessionID: UUID()) { events.append($0); return true })
        _ = value.beginActivation(contact: 1, sessionID: value.sessionID) { _ in true }
        XCTAssertFalse(value.begin(contact: 2, at: center(value, f.b), sessionID: value.sessionID) { events.append($0); return true })
        XCTAssertFalse(try value.move(contact: 2, through: [center(value, f.b)], sessionID: value.sessionID) { events.append($0); return true })
        XCTAssertFalse(try value.end(contact: 1, sessionID: UUID()) { events.append($0); return true })
        XCTAssertTrue(events.isEmpty); XCTAssertEqual(value.activeContact, 1)
    }

    func testContactCancelIsNotNormalLiftOrGlobalCleanup() throws {
        let f = Fixture(); var value = try session(f); var events: [FloatingButtonCommand] = []
        _ = value.beginActivation(contact: 1, sessionID: value.sessionID) { _ in true }
        _ = value.cancel(contact: 1, sessionID: value.sessionID) { events.append($0); return true }
        XCTAssertEqual(events, [.cancel(member: f.a, contact: 1)])
        XCTAssertFalse(value.isFinished); XCTAssertNil(value.capturedMemberID)
    }

    func testFinishScopeExcludesUnrelatedOwnerAndIsIdempotent() throws {
        let f = Fixture(); var value = try session(f); let unrelated = UUID()
        var held: Set<UUID> = [f.a, f.b, unrelated]; var commands: [FloatingButtonCommand] = []
        let token = value.sessionID
        XCTAssertTrue(value.finish(sessionID: token) { event in
            commands.append(event)
            if case .finishScope(let ids) = event { held.subtract(ids) }
            return true
        })
        XCTAssertEqual(held, [unrelated])
        XCTAssertFalse(value.finish(sessionID: token) { commands.append($0); return true })
        XCTAssertFalse(value.beginActivation(contact: 1, sessionID: token) { commands.append($0); return true })
        XCTAssertEqual(commands.count, 1)
    }

    func testRejectedInitialBeginCannotBecomeSwipeActivation() throws {
        let f = Fixture(); var value = try session(f); var events: [FloatingButtonCommand] = []
        _ = value.beginActivation(contact: 1, sessionID: value.sessionID) { _ in false }
        _ = try value.move(contact: 1, through: [center(value, f.b)], sessionID: value.sessionID) { events.append($0); return true }
        XCTAssertNil(value.capturedMemberID); XCTAssertTrue(events.isEmpty)
    }

    func testSettingsRoundTripAndStrictUnknownKeys() throws {
        let f = Fixture(); let data = try JSONEncoder().encode(f.zone)
        XCTAssertEqual(try JSONDecoder().decode(FloatingButtonZone.self, from: data), f.zone)
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object["futureOption"] = true
        XCTAssertThrowsError(try JSONDecoder().decode(FloatingButtonZone.self, from: JSONSerialization.data(withJSONObject: object)))
    }

    func testCollectionRejectsCrossPageNonbuttonAndDuplicateMembership() throws {
        let f = Fixture(); let second = FloatingButtonZone(name: "Other", kind: .singleButton, memberIDs: [f.a], startMemberID: f.a,
                                                          portraitGeometry: f.zone.portraitGeometry)
        XCTAssertThrowsError(try FloatingButtonZone.validate([f.zone, second], pageControlIDs: [f.a, f.b], buttonIDs: [f.a, f.b]))
        XCTAssertThrowsError(try FloatingButtonZone.validate([f.zone], pageControlIDs: [f.a, f.b], buttonIDs: [f.a]))
        XCTAssertThrowsError(try FloatingButtonZone.validate([f.zone], pageControlIDs: [f.a], buttonIDs: [f.a]))
    }

    func testMissingRestorationDuplicateMemberAndDisabledZoneAreExplicit() throws {
        let f = Fixture(); var zone = f.zone
        zone.portraitRestoration.removeLast(); XCTAssertThrowsError(try zone.validate())
        zone = f.zone; zone.memberIDs.append(f.a); XCTAssertThrowsError(try zone.validate())
        zone = f.zone; zone.enabled = false; XCTAssertNoThrow(try zone.validate())
        XCTAssertThrowsError(try session(f, zone: zone))
        XCTAssertEqual(Set(zone.memberIDs), [f.a, f.b]) // Disabling does not implicitly restore/hide ownership differently.
    }

    func testSingleButtonUsesCanonicalFallbackAndRequiresItsStart() throws {
        let id = UUID(); let rect = FloatingRect(x: 40, y: 80, width: 60, height: 60)
        var zone = FloatingButtonZone(kind: .singleButton, memberIDs: [id], startMemberID: id,
                                      portraitGeometry: .init(canvasWidth: 500, canvasHeight: 700,
                                                              zone: .init(x: 0, y: 0, width: 250, height: 700)))
        XCTAssertEqual(try zone.resolvedMembers(for: .portrait, canonical: [id: rect]), [.init(id: id, frame: rect)])
        zone.startMemberID = nil; XCTAssertThrowsError(try zone.validate())
    }

    func testNonfiniteGeometryAndInvalidRoutingAreRejected() throws {
        XCTAssertNil(FloatingGeometry.place(width: 100, height: 100, anchor: .init(x: .infinity, y: 0), touch: .init(x: 100, y: 100), usable: canvas))
        XCTAssertNil(FloatingGeometry.bounds(of: [.init(x: 0, y: 0, width: -1, height: 10)]))
        let f = Fixture()
        XCTAssertThrowsError(try session(f, routing: .init(transferableMembers: [f.a], entryEnabledMembers: [f.b])))
    }
}
