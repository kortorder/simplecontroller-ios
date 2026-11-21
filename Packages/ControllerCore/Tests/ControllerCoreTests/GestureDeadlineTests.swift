import Foundation
import XCTest
@testable import ControllerCore

final class GestureDeadlineTests: XCTestCase {
    private let uptimes = [10.0, 3_000_000.0, 10_000_000.0]
    private let pointer = ButtonPointerSample(x: 50, y: 50, width: 100, height: 100)
    private func profile(_ controls: [ProfileControl], turbo: Bool = false) throws -> ControllerProfile {
        let placements = controls.map { ProfilePlacement(id: $0.id, position: .init(x: 0.5, y: 0.5)) }
        return try .init(controls: controls, portrait: placements, landscape: placements,
                         turboEnabled: turbo, turboIntervalMilliseconds: 16)
    }
    private func sample(radius: Double, elapsed: Double = 0) -> TouchAimSample {
        .init(pointer: pointer, metrics: .init(majorRadius: radius), elapsed: elapsed)
    }
    private func sensor() -> ProfileControl {
        var control = ProfileControl(kind: .touchAim)
        control.touchAim.aim.output = .mouse
        control.touchAim.mode = .manualTwoState
        control.touchAim.twoState.smoothing = 1
        return control
    }
    private func aim(_ payload: String) -> ProfileControl {
        .init(payload: payload, buttonAim: .init(enabled: true, tuning: .init(output: .mouse)))
    }
    private func tickNext(_ engine: inout ProfileInputEngine, file: StaticString = #filePath, line: UInt = #line) throws -> Double {
        let due = try XCTUnwrap(engine.nextDeadline, file: file, line: line)
        try engine.tick(at: due)
        return due
    }

    func testTouchAimConfirmationConsumesItsAdvertisedAbsoluteDeadlineAtLongUptime() throws {
        for start in uptimes {
            let control = sensor()
            var engine = try ProfileInputEngine(profile: profile([control]))
            try engine.beginTouchAim(contact: 1, control: control.id, sample: sample(radius: 6), at: start)
            let due = try XCTUnwrap(engine.nextDeadline)
            try engine.tick(at: due - 0.000_001)
            XCTAssertEqual(engine.touchAimStates[control.id], .aim)
            try engine.tick(at: due)
            XCTAssertEqual(engine.touchAimStates[control.id], .shoot, "uptime \(start)")
            XCTAssertEqual(engine.practiceState.rightTrigger, 1)
            XCTAssertNil(engine.nextDeadline)
            // A rounded-up detector time must not make a repeated same-time tick regress.
            XCTAssertNoThrow(try engine.tick(at: due))
        }
    }

    func testTouchAimReturnConfirmationAndFiniteShotBothConsumeTheirDeadlines() throws {
        for start in uptimes {
            var control = sensor()
            control.touchAim.twoState.shootBehavior = .pressOnReturn
            var engine = try ProfileInputEngine(profile: profile([control]))
            try engine.beginTouchAim(contact: 1, control: control.id, sample: sample(radius: 6), at: start)
            _ = try tickNext(&engine)
            try engine.moveTouchAimBatch(contact: 1, samples: [sample(radius: 1, elapsed: 0.2)], at: start + 0.2)
            _ = try tickNext(&engine)
            XCTAssertEqual(engine.touchAimStates[control.id], .aim)
            XCTAssertEqual(engine.practiceState.rightTrigger, 1)
            _ = try tickNext(&engine)
            XCTAssertEqual(engine.practiceState.rightTrigger, 0)
            XCTAssertNil(engine.nextDeadline)
        }
    }

    func testAdvancedButtonPulseExpiresAtItsAdvertisedDeadlineAndRestoresAnotherOwner() throws {
        for start in uptimes {
            let control = aim("RT:1P0.3"), other = ProfileControl(payload: "RT:0.25")
            var engine = try ProfileInputEngine(profile: profile([control, other]))
            try engine.begin(contact: 2, control: other.id, at: start)
            try engine.beginButton(contact: 1, control: control.id, sample: pointer, at: start)
            XCTAssertEqual(engine.practiceState.rightTrigger, 1)
            _ = try tickNext(&engine)
            XCTAssertEqual(engine.practiceState.rightTrigger, 0.25, "uptime \(start)")
            XCTAssertNil(engine.nextDeadline)
        }
    }

    func testTouchAimOwnedPulseExpiresWhileItsStageRemainsHeld() throws {
        for start in uptimes {
            var control = sensor()
            control.touchAim.mode = .manualThreeStage
            control.touchAim.threeStage.smoothing = 1
            control.touchAim.threeStage.medium.payload = ""
            control.touchAim.threeStage.high.payload = "RT:1P0.3"
            var engine = try ProfileInputEngine(profile: profile([control]))
            try engine.beginTouchAim(contact: 1, control: control.id, sample: sample(radius: 6), at: start)
            XCTAssertEqual(engine.practiceState.rightTrigger, 1)
            _ = try tickNext(&engine)
            XCTAssertEqual(engine.practiceState.rightTrigger, 0, "uptime \(start)")
            XCTAssertEqual(engine.touchAimStates[control.id], .high)
            XCTAssertNil(engine.nextDeadline)
        }
    }

    func testLatchedAdvancedPulseKeepsSchedulingEveryOnAndOffBoundary() throws {
        for start in uptimes {
            var control = aim("RT:1P0.3")
            control.buttonAim.payloadTiming = .sendOnRelease
            control.buttonBehavior = .init(holdToggle: true, holdMilliseconds: 500)
            var engine = try ProfileInputEngine(profile: profile([control]))
            try engine.beginButton(contact: 1, control: control.id, sample: pointer, at: start)
            _ = try tickNext(&engine)
            try engine.end(contact: 1, at: start + 0.6)
            XCTAssertEqual(engine.practiceState.rightTrigger, 1)
            for boundary in 1...12 {
                _ = try tickNext(&engine)
                XCTAssertEqual(engine.practiceState.rightTrigger, boundary.isMultiple(of: 2) ? 1 : 0,
                               "uptime \(start), boundary \(boundary)")
                XCTAssertNotNil(engine.nextDeadline)
            }
        }
    }

    func testAdvancedTurboDigitalAndMacroPhasesAgreeAtEveryAdvertisedDeadline() throws {
        for start in uptimes {
            let control = aim("X360A,RS:R50")
            var engine = try ProfileInputEngine(profile: profile([control], turbo: true))
            try engine.beginButton(contact: 1, control: control.id, sample: pointer, at: start)
            for boundary in 1...12 {
                _ = try tickNext(&engine)
                let on = boundary.isMultiple(of: 2)
                XCTAssertEqual(engine.state.buttons.contains(.a), on, "uptime \(start), boundary \(boundary)")
                XCTAssertEqual(engine.state.rightStick.x, on ? 0.5 : 0)
                XCTAssertNotNil(engine.nextDeadline)
            }
        }
    }

    func testCancellationWinsOverUnobservedConfirmationAndPulseExpiry() throws {
        for start in uptimes {
            let control = sensor(), button = aim("RT:1P0.3"), other = ProfileControl(actions: [.b])
            var engine = try ProfileInputEngine(profile: profile([control, button, other]))
            try engine.begin(contact: 3, control: other.id, at: start)
            try engine.beginTouchAim(contact: 1, control: control.id, sample: sample(radius: 6), at: start)
            let due = try XCTUnwrap(engine.nextDeadline)
            try engine.cancel(contact: 1, at: due)
            XCTAssertEqual(engine.practiceState.rightTrigger, 0)
            XCTAssertNil(engine.nextDeadline)
            try engine.beginButton(contact: 2, control: button.id, sample: pointer, at: due)
            let pulseDue = try XCTUnwrap(engine.nextDeadline)
            try engine.cancel(contact: 2, at: pulseDue)
            try engine.tick(at: pulseDue + 1)
            XCTAssertEqual(engine.state.buttons, [.b])
            XCTAssertEqual(engine.practiceState.rightTrigger, 0)
            XCTAssertNil(engine.nextDeadline)
        }
    }

    func testLateAdvancedTurboWakePublishesOnlyCurrentPhaseWithoutCatchUpEdges() throws {
        let start = 3_000_000.0, control = aim("W,RS:R50")
        var engine = try ProfileInputEngine(profile: profile([control], turbo: true))
        try engine.beginButton(contact: 1, control: control.id, sample: pointer, at: start)
        _ = engine.drainPracticeEvents()
        try engine.tick(at: start + 5.004) // 312 full 16 ms cycles, then the current OFF gap.
        XCTAssertTrue(engine.practiceState.heldKeys.isEmpty)
        XCTAssertEqual(engine.state.rightStick, .zero)
        XCTAssertEqual(engine.drainPracticeEvents().events.filter { if case .keyUp(.w) = $0.kind { true } else { false } }.count, 1)
        try engine.tick(at: start + 5.004)
        XCTAssertTrue(engine.drainPracticeEvents().events.isEmpty)
        let due = try tickNext(&engine)
        XCTAssertEqual(due, start + 5.008, accuracy: 1e-8)
        XCTAssertEqual(engine.practiceState.heldKeys, [.w])
        XCTAssertEqual(engine.state.rightStick.x, 0.5)
        XCTAssertEqual(engine.drainPracticeEvents().events.filter { if case .keyDown(.w) = $0.kind { true } else { false } }.count, 1)
    }
}
