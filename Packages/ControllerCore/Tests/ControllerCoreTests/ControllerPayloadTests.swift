import Foundation
import XCTest
@testable import ControllerCore

final class ControllerPayloadTests: XCTestCase {
    func testControllerCommandsCaseWhitespaceAndAliasesCanonicalize() throws {
        let program = try ControllerPayloadProgram.parse(" x360a , X360LSTICK, x360rs, X360View, x360menu, x360guide, x360share, x360dpadup ")
        XCTAssertEqual(program.source, "X360A, X360LSC, X360RSC, X360BACK, X360START, X360GUIDE, X360SHARE, X360UP")
        XCTAssertEqual(program.outputTargets, [.a, .leftStickClick, .rightStickClick, .view, .menu, .guide, .share, .dpadUp])
        XCTAssertFalse(program.containsWaitOrPulse)
        XCTAssertEqual(try ControllerPayloadProgram.parse(program.source), program)
    }
    func testTriggerPressurePulseWaitParseAndReportPotentialTargets() throws {
        let program = try ControllerPayloadProgram.parse("lt:.5, WAIT_1000, rt:1P.3, LT:0")
        XCTAssertEqual(program.steps, [.triggerPressure(.left, 0.5), .wait(milliseconds: 1000), .triggerPulse(.right, 1, duration: 0.3), .triggerPressure(.left, 0)])
        XCTAssertEqual(program.outputTargets, [.leftTrigger, .rightTrigger])
        XCTAssertTrue(program.containsWaitOrPulse)
        XCTAssertEqual(try ControllerPayloadProgram.parse("LT:0, RT:0P0.01, WAIT_0").outputTargets, [])
    }
    func testAllNativeActionsHaveLosslessSupportedCanonicalCommands() throws {
        let actions = Set(ControllerControlID.allCases.filter { !$0.isStick })
        let program = try ControllerPayloadProgram.parse(ControllerPayloadProgram.source(for: actions))
        XCTAssertEqual(program.outputTargets, actions)
    }
    func testTinyDecimalCanonicalSourceRemainsParseableWithoutExponentNotation() throws {
        for source in ["LT:0.00000001", "RT:0.000000000000000000000001P0.3",
                       "LT:0." + String(repeating: "0", count: 310) + "1"] {
            let program = try ControllerPayloadProgram.parse(source)
            XCTAssertFalse(program.source.lowercased().contains("e"))
            XCTAssertEqual(try ControllerPayloadProgram.parse(program.source), program)
        }
    }
    func testUnknownOrMalformedTokenRejectsEntireProgramWithPosition() {
        for bad in ["NOT_A_KEY", "SCROLL:1", "X360A_HOLD", "X360A_RELEASE", "X360ZZ", "", "X360A X360B"] {
            XCTAssertThrowsError(try ControllerPayloadProgram.parse("X360A, \(bad), X360B")) {
                XCTAssertTrue($0.localizedDescription.contains("Command 2"))
            }
        }
    }
    func testX360TriggerPrefixIsRejectedWithCorrectSyntaxGuidance() {
        for token in ["X360LT", "X360RT", "X360LT:0.5", "X360RT:1P.3"] {
            XCTAssertThrowsError(try ControllerPayloadProgram.parse(token)) {
                XCTAssertTrue($0.localizedDescription.contains("Use LT:0.5 or RT:1.0P0.3"))
            }
        }
    }
    func testPressureAndPulseFiniteDecimalBounds() throws {
        for valid in ["LT:0", "RT:1", "LT:.5", "RT:1P0.01", "LT:0.2P60"] { XCTAssertNoThrow(try ControllerPayloadProgram.parse(valid)) }
        for bad in ["LT:-0.1", "RT:1.01", "LT:NaN", "RT:INF", "LT:1e-2", "RT:0x1", "LT:.", "RT:1P0", "LT:1P.009", "LT:1P60.1", "RT:1PNaN", "RT:1P1P1"] {
            XCTAssertThrowsError(try ControllerPayloadProgram.parse(bad), bad)
        }
    }
    func testWaitIntegerSingleAndTotalLimits() throws {
        XCTAssertNoThrow(try ControllerPayloadProgram.parse("WAIT_60000, WAIT_60000"))
        for bad in ["WAIT_-1", "WAIT_1.0", "WAIT_60001", "WAIT_", "WAIT_60000,WAIT_60000,WAIT_1"] {
            XCTAssertThrowsError(try ControllerPayloadProgram.parse(bad), bad)
        }
    }
    func testSourceAndTokenBoundsIncludingBlankProgram() throws {
        XCTAssertEqual(try ControllerPayloadProgram.parse(" \n ").steps, [])
        XCTAssertNoThrow(try ControllerPayloadProgram.parse(Array(repeating: "X360A", count: 64).joined(separator: ",")))
        XCTAssertThrowsError(try ControllerPayloadProgram.parse(Array(repeating: "X360A", count: 65).joined(separator: ",")))
        XCTAssertThrowsError(try ControllerPayloadProgram.parse(String(repeating: " ", count: 8193)))
    }
    func testPayloadReplacesPreservedActionsAndInvalidDraftTargetsAreEmpty() throws {
        var button = ProfileControl(actions: [.a], payload: "RT:0.4")
        XCTAssertEqual(button.outputTargets, [.rightTrigger])
        XCTAssertEqual(button.actions, [.a])
        button.payload = "unsupported"
        XCTAssertEqual(button.outputTargets, [])
        XCTAssertThrowsError(try button.validate())
        button.payload = nil
        XCTAssertEqual(button.outputTargets, [.a])
    }
    func testAutoTapRejectsConflictingModesAndTimingOutsideBounds() throws {
        XCTAssertNoThrow(try ProfileControl(payload: "RT:0.5, X360A", autoTapEnabled: true, autoTapIntervalMilliseconds: 16).validate())
        for payload in ["WAIT_0, X360A", "RT:1P0.3"] {
            XCTAssertThrowsError(try ProfileControl(payload: payload, autoTapEnabled: true).validate()) {
                XCTAssertTrue($0.localizedDescription.contains("AutoTap cannot contain WAIT"))
            }
        }
        XCTAssertThrowsError(try ProfileControl(buttonBehavior: .init(holdToggle: true), autoTapEnabled: true).validate())
        for interval in [15, 1001] { XCTAssertThrowsError(try ProfileControl(autoTapIntervalMilliseconds: interval).validate()) }
        for interval in [9, 1001] { XCTAssertThrowsError(try ControllerProfile(turboIntervalMilliseconds: interval)) }
        XCTAssertThrowsError(try ProfileControl(kind: .recenter, payload: "X360A").validate())
    }
}
