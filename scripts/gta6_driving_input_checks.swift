import Foundation
import CryptoKit
import Darwin
import ControllerCore

/// Real prepared controls through production input code; no network or hardware.
@main
struct VerifyGTA6ActualInputs {
    static func main() throws {
        guard CommandLine.arguments.count == 4 else {
            fatalError("Usage: verify-actual-inputs BEFORE_JSON CANDIDATE_JSON REPORT_JSON")
        }
        let beforeRaw = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let candidateRaw = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        let before = try ControllerProfileLibraryCodec.decode(beforeRaw)
        let candidate = try ControllerProfileLibraryCodec.decode(candidateRaw)
        let profile = candidate.profiles.first { $0.id.uuidString == "FE38F861-119A-49F1-8347-1BCF69676076" }!
        let previous = before.profiles.first { $0.id == profile.id }!
        let walk = profile.pages.first { $0.name == "Walk" }!
        let drive = profile.pages.first { $0.name == "Drive" }!
        var checks = 0
        var failures: [String] = []
        func require(_ condition: @autoclosure () -> Bool, _ label: String) {
            checks += 1
            if !condition() { failures.append(label); print("FAIL: \(label)") }
        }
        func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.000_001 }
        func pressure(_ e: ProfileInputEngine, _ lt: Double, _ rt: Double) -> Bool {
            close(e.practiceState.leftTrigger, lt) && close(e.practiceState.rightTrigger, rt)
        }
        func neutral(_ e: ProfileInputEngine) -> Bool {
            e.state.isNeutral && pressure(e, 0, 0) && e.latchedControls.isEmpty
        }
        func control(_ name: String, on page: ProfilePage) -> ProfileControl {
            profile.controls(on: page.id).first { $0.name == name }!
        }
        func engine(on page: ProfilePage) throws -> ProfileInputEngine {
            var result = try ProfileInputEngine(profile: profile)
            if result.currentPageID != page.id { _ = try result.selectPage(page.id, at: 0) }
            return result
        }
        func point(_ c: ProfileControl, _ x: Double = 0, _ y: Double = 0) -> ButtonPointerSample {
            let dims = c.dimensions(for: .portrait)
            return .init(x: dims.width / 2 + x, y: dims.height / 2 + y, width: dims.width, height: dims.height)
        }
        func begin(_ e: inout ProfileInputEngine, _ c: ProfileControl, _ time: Double, contact: Int = 1) throws {
            try e.beginButton(contact: contact, control: c.id, sample: point(c), at: time)
        }
        func move(_ e: inout ProfileInputEngine, _ c: ProfileControl, _ x: Double, _ y: Double,
                  _ time: Double, contact: Int = 1) throws {
            try e.moveButtonBatch(contact: contact, samples: [point(c, x, y)], at: time)
        }
        require(candidate.profiles.count == before.profiles.count && profile.controls.count == 62, "All profiles and intended GTA control count decode")
        require(!profile.turboEnabled && !profile.globalHoldEnabled, "No profile-wide Turbo/Hold changes gesture semantics")
        require(candidate.profiles.filter { $0.id != profile.id } == before.profiles.filter { $0.id != profile.id },
                "Every other profile remains identical through native decoding")

        let wheel = control("Wheel", on: walk)
        var e = try engine(on: walk)
        try begin(&e, wheel, 1)
        require(e.state.buttons == [.leftBumper] && e.state.rightStick == .zero && pressure(e, 0, 0), "Wheel immediately holds only LB")
        try move(&e, wheel, 32, 0, 1.1)
        require(close(e.state.rightStick.x, 1) && close(e.state.rightStick.y, 0), "Wheel selects right-stick right")
        try move(&e, wheel, 0, -32, 1.2)
        require(close(e.state.rightStick.y, 1) && e.state.buttons == [.leftBumper], "Wheel selects up while LB stays held")
        try e.tick(at: 2)
        require(e.state.buttons == [.leftBumper], "Wheel holds LB continuously")
        try e.end(contact: 1, at: 2.1)
        require(neutral(e), "Wheel lift releases LB and right-stick motion")
        let dpad = control("D-pad", on: walk)
        require(dpad == previous.control(for: dpad.id), "Existing swipe D-pad settings unchanged")
        try begin(&e, dpad, 3)
        require(neutral(e), "D-pad center touch has no fallback action")
        var t = 3.1
        for (x, y, direction) in [(0.0, -20.0, DPadDirection.up), (20, 0, .right), (0, 20, .down), (-20, 0, .left)] {
            try move(&e, dpad, x, y, t)
            require(e.state.dpad == direction && e.state.buttons.isEmpty && pressure(e, 0, 0), "D-pad emits intended cardinal direction")
            t += 0.1
        }
        try e.end(contact: 1, at: 4)
        require(neutral(e), "D-pad lift releases direction")

        let steer = control("Steer", on: drive)
        e = try engine(on: drive)
        try begin(&e, steer, 1)
        require(neutral(e), "Steer center sends no base trigger or button")
        try move(&e, steer, 35.9, 0, 1.1)
        require(!e.state.buttons.contains(.a) && pressure(e, 0, 0), "Partial steering does not press A or triggers")
        try move(&e, steer, 36, 0, 1.2)
        require(close(e.state.leftStick.x, 1) && e.state.buttons == [.a] && pressure(e, 0, 0), "Full right starts one A tap with no acceleration/brake")
        try move(&e, steer, 80, 0, 1.25)
        try e.tick(at: 1.299)
        require(e.state.buttons.contains(.a), "A pulse remains active just before 100 ms")
        try e.tick(at: 1.301)
        require(e.state.buttons.isEmpty && close(e.state.leftStick.x, 1), "A pulse ends after 100 ms despite crossing second distance")
        try e.tick(at: 2)
        require(e.state.buttons.isEmpty && pressure(e, 0, 0), "Remaining at full edge does not repeat A")
        try move(&e, steer, 32, 0, 2.1)
        try move(&e, steer, 36, 0, 2.2)
        require(e.state.buttons.isEmpty, "Four-point hysteresis boundary does not spuriously rearm")
        try move(&e, steer, 31, 0, 2.3)
        try move(&e, steer, 36, 0, 2.4)
        require(e.state.buttons == [.a], "Moving inward past rearm margin permits next edge tap")
        try e.tick(at: 2.501)
        require(e.state.buttons.isEmpty, "Rearmed right pulse is finite")
        try move(&e, steer, 0, 0, 2.6)
        try move(&e, steer, -36, 0, 2.7)
        require(close(e.state.leftStick.x, -1) && e.state.buttons == [.a] && pressure(e, 0, 0), "Full left starts one A tap")
        try e.tick(at: 2.801)
        require(e.state.buttons.isEmpty, "Left edge pulse releases after 100 ms")
        try move(&e, steer, 0, -36, 2.9)
        require(close(e.state.leftStick.y, 1) && e.state.buttons.isEmpty && pressure(e, 0, 0), "Up steering does not add A or triggers")
        try move(&e, steer, 0, 36, 3)
        require(close(e.state.leftStick.y, -1) && e.state.buttons.isEmpty && pressure(e, 0, 0), "Down steering does not add A or triggers")
        try e.end(contact: 1, at: 3.1)
        require(neutral(e), "Steer lift centers the left stick")
        for (name, lt, rt) in [("Accelerate", 0.0, 1.0), ("Brake", 1.0, 0.0)] {
            let c = control(name, on: drive)
            e = try engine(on: drive)
            try e.begin(contact: 1, control: c.id, at: 1)
            require(pressure(e, lt, rt) && e.state.leftStick == .zero && e.state.rightStick == .zero && e.state.dpad == .neutral,
                    "Trigger-only control activates just its trigger without steering")
            try e.end(contact: 1, at: 1.1)
            require(neutral(e), "Trigger-only control releases on lift")
        }

        let expectedFaces: [String: PadButton] = ["X360A": .a, "X360B": .b, "X360X": .x, "X360Y": .y]
        let faces = profile.controls.filter { $0.kind == .button && expectedFaces[$0.payload ?? ""] != nil }
        require(faces.count == 7, "Every eligible GTA face control is covered, across all three gameplay pages")
        for c in faces {
            let button = expectedFaces[c.payload!]!
            let page = profile.pages.first { $0.controlIDs.contains(c.id) }!
            require(c.doubleTapRepeatEnabled && c.buttonBehavior.holdToggle && c.buttonBehavior.holdMilliseconds == 500 &&
                    !c.autoTapEnabled && c.autoTapIntervalMilliseconds == 100, "Face control enables chosen hold and double-tap behavior")
            e = try engine(on: page)
            try e.begin(contact: 1, control: c.id, at: 1)
            require(e.state.buttons == [button], "Face touch starts ordinary press")
            try e.tick(at: 1.499)
            require(!e.latchedControls.contains(c.id), "Face hold does not latch early")
            try e.tick(at: 1.5)
            try e.end(contact: 1, at: 1.51)
            require(e.latchedControls.contains(c.id) && e.state.buttons == [button], "Face hold latches after threshold and lift")
            try e.begin(contact: 2, control: c.id, at: 2)
            try e.end(contact: 2, at: 2.05)
            require(neutral(e), "One tap stops the steady face hold")
            e = try engine(on: page)
            try e.begin(contact: 1, control: c.id, at: 1)
            try e.end(contact: 1, at: 1.05)
            try e.begin(contact: 2, control: c.id, at: 1.15)
            try e.end(contact: 2, at: 1.2)
            require(e.latchedControls.contains(c.id) && e.state.buttons.isEmpty, "Double tap starts latched repetition after second lift")
            try e.tick(at: 1.251)
            require(e.state.buttons == [button], "Repeat pulse turns on after initial release gap")
            try e.tick(at: 1.301)
            require(e.state.buttons.isEmpty, "Repeat pulse releases between presses")
            try e.tick(at: 1.351)
            require(e.state.buttons == [button], "Repeat continues without a held finger")
            try e.begin(contact: 3, control: c.id, at: 1.36)
            try e.end(contact: 3, at: 1.4)
            try e.tick(at: 2)
            require(neutral(e), "One tap stops continuous repetition without a final extra pulse")
        }

        let pickup = control("LB", on: walk)
        let retainedMove = control("Move - stays", on: walk)
        let fire = control("RT fire", on: walk)
        let look = control("Look", on: walk)
        require(pickup.centerLeftStickBeforePress && pickup.macroModeEnabled && pickup.payload == "X360LB(D50)(U150)" &&
                !pickup.buttonAim.enabled && !pickup.buttonDirectional.enabled, "LB uses scoped stop-left plus finite delayed press")
        e = try engine(on: walk)
        try e.begin(contact: 1, control: retainedMove.id, position: .init(x: 0.6, y: 0.2), at: 1)
        try e.end(contact: 1, at: 1.1)
        require(e.state.leftStick != .zero && e.retainedSticks[retainedMove.id] != nil, "Existing movement is retained before pickup")
        try e.begin(contact: 2, control: fire.id, at: 1.2)
        try e.begin(contact: 3, control: look.id, position: .init(x: 0.3, y: 0.4), at: 1.3)
        let rightBefore = e.state.rightStick
        try e.begin(contact: 4, control: pickup.id, at: 1.4)
        require(e.state.leftStick == .zero && e.retainedSticks[retainedMove.id] == nil &&
                !e.state.buttons.contains(.leftBumper), "Pickup immediately centers only left-stick ownership before LB")
        require(pressure(e, 0, 1) && e.state.rightStick == rightBefore, "Pickup preserves independent RT and right-stick owners")
        try e.end(contact: 4, at: 1.41)
        try e.tick(at: 1.449)
        require(!e.state.buttons.contains(.leftBumper), "LB does not activate before the 50 ms neutral interval")
        try e.tick(at: 1.451)
        require(e.state.buttons.contains(.leftBumper) && e.state.leftStick == .zero && pressure(e, 0, 1), "LB press completes after finger lift")
        try e.tick(at: 1.599)
        require(e.state.buttons.contains(.leftBumper), "LB remains held for intended finite pulse")
        try e.tick(at: 1.601)
        require(!e.state.buttons.contains(.leftBumper) && e.state.leftStick == .zero &&
                e.state.rightStick == rightBefore && pressure(e, 0, 1), "LB releases at150ms without resuming walk or releasing other owners")
        try e.end(contact: 2, at: 1.7)
        try e.end(contact: 3, at: 1.8)
        require(neutral(e), "Remaining independent owners release normally")

        let report: [String: Any] = ["status": failures.isEmpty ? "pass" : "fail", "checks": checks,
            "failures": failures, "candidateBytes": candidateRaw.count,
            "candidateSHA256": SHA256.hash(data: candidateRaw).map { String(format: "%02x", $0) }.joined(),
            "scope": "Actual private candidate through production core; no network/hardware output"]
        try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
            .write(to: URL(fileURLWithPath: CommandLine.arguments[3]), options: .atomic)
        print("\(failures.isEmpty ? "PASS" : "FAIL"): \(checks) actual-candidate input checks; \(failures.count) failures.")
        if !failures.isEmpty { exit(1) }
    }
}
