import Foundation
import CryptoKit
import Darwin
import ControllerCore

// Supplemental checks for the approved delta from the existing GTA layout.
// The general GTA profile checks separately cover driving, ring actions and app import.
@main
struct GTAPrepProfileChecks {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            fatalError("Usage: check_gta_prep_profile BASELINE_JSON PREP_JSON")
        }
        var count = 0
        var failures: [String] = []
        func require(_ condition: Bool, _ message: String) {
            count += 1
            if !condition { failures.append(message); print("FAIL: \(message)") }
        }
        func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-8 }
        func overlaps(_ a: FloatingRect, _ b: FloatingRect) -> Bool {
            min(a.x + a.width, b.x + b.width) > max(a.x, b.x) + 1e-8 &&
            min(a.y + a.height, b.y + b.height) > max(a.y, b.y) + 1e-8
        }
        let baselineData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        let baselineLibrary = try ControllerProfileLibraryCodec.decode(baselineData)
        let library = try ControllerProfileLibraryCodec.decode(data)
        let baseline = baselineLibrary.activeProfile, profile = library.activeProfile
        require(library.version == ControllerProfileLibrary.currentVersion && library.profiles.count == 1 && profile.name == "GTA 6 Prep",
                "The additive document contains one native format-20 GTA 6 Prep profile")
        require(try ControllerProfileLibraryCodec.decode(ControllerProfileLibraryCodec.encode(library)) == library,
                "The complete new library round-trips through the actual codec")
        require(profile.pages.map(\.name) == ["Walk", "Aim", "Drive", "Extras"] && profile.controls.count == 50,
                "All four pages and all 50 controls remain")
        func page(_ name: String, in p: ControllerProfile = profile) -> ProfilePage { p.pages.first { $0.name == name }! }
        func control(_ name: String, on pageName: String, in p: ControllerProfile = profile) -> ProfileControl {
            p.controls(on: page(pageName, in: p).id).first { $0.name == name }!
        }
        func position(_ control: ProfileControl, in p: ControllerProfile = profile) -> NormalizedControlPosition {
            p.portrait.first { $0.id == control.id }!.position
        }
        let move = control("Move - stays", on: "Walk"), look = control("Look", on: "Walk")
        let run = control("Run A", on: "Walk"), center = control("Center sticks", on: "Walk")
        let directAim = control("Aim + fire", on: "Walk")
        let ring = page("Aim").floatingRingZones[0]

        // Remap only cloned identities back to the baseline, then compare every
        // saved field after removing precisely the approved edits below.
        var ids: [String: String] = [profile.id.uuidString: baseline.id.uuidString]
        for p in profile.pages {
            let old = page(p.name, in: baseline)
            ids[p.id.uuidString] = old.id.uuidString
            for c in profile.controls(on: p.id) {
                let originalName = p.name == "Walk" && c.name == "Aim + fire" ? "Aim" : c.name
                ids[c.id.uuidString] = control(originalName, on: p.name, in: baseline).id.uuidString
            }
            for zone in p.floatingRingZones {
                ids[zone.id.uuidString] = old.floatingRingZones.first { $0.name == zone.name }!.id.uuidString
            }
        }
        require(profile.id != baseline.id &&
                Set(profile.controls.map(\.id)).isDisjoint(with: Set(baseline.controls.map(\.id))) &&
                Set(profile.pages.map(\.id)).isDisjoint(with: Set(baseline.pages.map(\.id))) &&
                ring.id != page("Aim", in: baseline).floatingRingZones[0].id,
                "Profile, page, control and ring identities are distinct from the existing GTA profile")
        func remap(_ value: Any) -> Any {
            if let text = value as? String { return ids[text] ?? text }
            if let array = value as? [Any] { return array.map(remap) }
            if let object = value as? [String: Any] { return object.mapValues(remap) }
            return value
        }
        let encodedProfile = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile))
        let normalizedData = try JSONSerialization.data(withJSONObject: remap(encodedProfile))
        var reverted = try JSONDecoder().decode(ControllerProfile.self, from: normalizedData)
        reverted.name = baseline.name
        let moved: [String: [(String, Double, Double)]] = [
            "Walk": [("Move - stays", 56, 366), ("Look", 56, 250), ("Extras", 40, 142),
                     ("Stop all", 121, 142), ("Jump X", 141, 194), ("Car Y", 141, 246),
                     ("Reload B", 141, 298), ("Cover RB", 141, 350), ("Center sticks", 141, 402)],
            "Aim": [("Stop fire", 40, 76), ("Release aim", 121, 76), ("Reload B", 40, 128),
                    ("Center sticks", 121, 128), ("Extras", 40, 180), ("Stop all", 121, 180)]
        ]
        for pageName in ["Walk", "Aim"] {
            let expected = moved[pageName]!
            require(expected.allSatisfy { name, x, y in
                let p = position(control(name, on: pageName))
                return close(p.x * 337, x) && close(p.y * 428, y)
            }, "\(pageName): every approved portrait position is exact")
            for (name, _, _) in expected {
                let old = control(name, on: pageName, in: baseline)
                let index = reverted.portrait.firstIndex { $0.id == old.id }!
                reverted.portrait[index] = baseline.portrait.first { $0.id == old.id }!
            }
        }
        var expectedMove = control("Move - stays", on: "Walk", in: baseline)
        expectedMove.id = move.id
        expectedMove.stickBehavior.stickPlusEnabled = true
        expectedMove.stickBehavior.superBoostThreshold = 0.95
        expectedMove.stickBehavior.directions[.up] = .init(superBoostControls: [.a])
        expectedMove.stickPlusRepeatIntervalMilliseconds = 200
        require(move == expectedMove, "Only the intended full-forward A repeat settings change on Move")
        var expectedCenter = control("Center sticks", on: "Walk", in: baseline)
        expectedCenter.id = center.id
        expectedCenter.orientationDimensions = .init(portrait: .init(width: 44, height: 44),
                                                    landscape: .init(width: 44, height: 44))
        require(center == expectedCenter, "Center sticks changes only to44-point circular dimensions in both orientations")
        var expectedAim = control("Aim", on: "Walk", in: baseline)
        expectedAim.id = directAim.id
        expectedAim.name = "Aim + fire"
        expectedAim.kind = .button
        expectedAim.pageNavigation = nil
        expectedAim.payload = "LT:0.5,RT:0.7"
        expectedAim.buttonAim = .init(enabled: true,
            tuning: .init(output: .rightStick, fullDisplacement: 60, deadzone: 4, autoCenter: true))
        require(directAim == expectedAim && !directAim.buttonBehavior.holdToggle &&
                !directAim.autoTapEnabled && !directAim.buttonAim.alternate.enabled,
                "The Walk Aim shortcut becomes only the requested momentary LT50/RT70 aiming pad")
        let circles = profile.controls.filter { !$0.kind.isStick && !$0.buttonAim.enabled }
        require(circles.count == 43 && circles.allSatisfy { c in
            c.controlWidth == nil && c.controlHeight == nil &&
            [ControllerOrientation.portrait, .landscape].allSatisfy { orientation in
                let size = c.dimensions(for: orientation)
                return size.width == 44 && size.height == 44
            }
        }, "All43 ordinary controls have44-point circular-rendering dimensions in both orientations")
        for c in circles {
            let oldID = UUID(uuidString: ids[c.id.uuidString]!)!
            let old = baseline.controls.first { $0.id == oldID }!
            let index = reverted.controls.firstIndex { $0.id == oldID }!
            // Allow only the explicit two-orientation size change, preserving
            // names, actions, placement order and all unrelated control fields.
            reverted.controls[index].orientationDimensions = old.orientationDimensions
        }
        for name in ["Move - stays", "Center sticks", "Aim"] {
            let old = control(name, on: "Walk", in: baseline)
            reverted.controls[reverted.controls.firstIndex { $0.id == old.id }!] = old
        }
        require(ring.portraitGeometry == .init(canvasWidth: 337, canvasHeight: 428,
                                             zone: .init(x: 4, y: 372, width: 48, height: 44)),
                "The ring activation zone is the approved lower-left rectangle")
        let aimIndex = reverted.pages.firstIndex { $0.name == "Aim" }!
        reverted.pages[aimIndex].floatingRingZones[0].portraitGeometry = page("Aim", in: baseline).floatingRingZones[0].portraitGeometry
        require(reverted == baseline,
                "Beyond approved edits and ordinary-button sizes, every saved field, behavior, reference, order and landscape center matches the baseline")
        let dragControls = profile.controls.filter { $0.buttonAim.enabled }
        require(dragControls.count == 5 && profile.controls.filter { $0.kind.isStick }.count == 2 &&
                profile.controls.filter { $0.kind.isStick || $0.buttonAim.enabled }.allSatisfy { c in
                    let originalID = UUID(uuidString: ids[c.id.uuidString]!)!
                    let original = baseline.controls.first { $0.id == originalID }!
                    return c.orientationDimensions == original.orientationDimensions &&
                        c.controlWidth == original.controlWidth && c.controlHeight == original.controlHeight
                }, "The two sticks and all five drag pads retain their exact original dimensions in both orientations")
        require(library.androidSources == baselineLibrary.androidSources && library.settingsPresets == baselineLibrary.settingsPresets,
                "No source archive or reusable preset changes accompany this profile")

        let usable = FloatingRect(x: 0, y: 0, width: 337, height: 428)
        func frame(_ c: ProfileControl) -> FloatingRect {
            let p = position(c), size = c.dimensions(for: .portrait)
            return .init(x: p.x * 337 - size.width / 2, y: p.y * 428 - size.height / 2,
                         width: size.width, height: size.height)
        }
        for pageName in ["Walk", "Aim"] {
            let frames = profile.controls(on: page(pageName).id).map(frame)
            require(frames.allSatisfy { usable.contains($0) && $0.x + $0.width <= 168.5 && $0.width >= 44 && $0.height >= 44 },
                    "\(pageName): all complete targets fit in the left half at usable touch sizes")
            require(frames.indices.allSatisfy { i in frames.indices.allSatisfy { j in j <= i || !overlaps(frames[i], frames[j]) } },
                    "\(pageName): no ordinary touch targets overlap")
        }
        require(close(frame(move).x, 4) && close(frame(move).y + frame(move).height, 418) &&
                close(frame(look).x, 4) && close(frame(move).y - frame(look).y - frame(look).height, 12),
                "Both104-point sticks stack4points from the left edge, with12points between them and10below Move")
        let ringGeometry = try FloatingRingGeometry(config: ring.config)
        let zone = try ring.portraitGeometry!.resolved(canvasWidth: 337, canvasHeight: 428)
        let aimFrames = profile.controls(on: page("Aim").id).map(frame)
        let points = [zone.center, FloatingPoint(x: zone.x, y: zone.y),
                      .init(x: zone.x + zone.width, y: zone.y),
                      .init(x: zone.x, y: zone.y + zone.height),
                      .init(x: zone.x + zone.width, y: zone.y + zone.height)]
        require(aimFrames.allSatisfy { !overlaps(zone, $0) }, "The ring activation area is not blocked by an ordinary button")
        for (index, point) in points.enumerated() {
            let placed = ringGeometry.place(at: point, usable: usable)
            require(placed != nil, "Ring sample\(index) has a valid placement")
            guard let placed else { continue }
            require(placed.bounds == .init(x: 0, y: 268, width: 112, height: 160) &&
                    usable.contains(placed.finish) && placed.finish.width >= 44 && placed.finish.height >= 44 &&
                    aimFrames.allSatisfy { !overlaps(placed.bounds, $0) && !overlaps(placed.finish, $0) },
                    "Ring sample\(index): complete ring and Finish stay at bottom-left and clear every button")
        }

        func engine() throws -> ProfileInputEngine { try ProfileInputEngine(profile: profile) }
        func neutral(_ e: ProfileInputEngine) -> Bool {
            e.state == .neutral && e.practiceState.leftTrigger == 0 && e.practiceState.rightTrigger == 0
        }
        var e = try engine()
        require(neutral(e) && e.nextDeadline == nil, "Loading the profile is neutral and schedules no repeat")
        try e.begin(contact: 1, control: move.id, position: .init(x: 0, y: 0.95), at: 1000)
        require(!e.state.buttons.contains(.a) && e.nextDeadline == nil, "Exactly95% forward does not repeat A")
        try e.move(contact: 1, position: .init(x: 0, y: 1), at: 1000.1)
        require(e.state.buttons == [.a] && e.state.leftStick == .init(x: 0, y: 1) && close(e.nextDeadline!, 1000.15),
                "Full forward immediately presses A without changing analog movement")
        try e.end(contact: 1, at: 1000.11)
        require(e.retainedSticks[move.id] == .init(x: 0, y: 1) && e.state.buttons == [.a],
                "Finger lift retains movement and its repeating stage")
        try e.tick(at: e.nextDeadline!)
        require(e.state.buttons.isEmpty && e.state.leftStick.y == 1 && close(e.nextDeadline!, 1000.3),
                "The actual first deadline releases A after50ms and schedules a150ms gap")
        try e.tick(at: e.nextDeadline!)
        require(e.state.buttons == [.a] && close(e.nextDeadline!, 1000.35), "The actual200ms deadline starts the next A press")
        try e.begin(contact: 2, control: move.id, position: .init(x: 0, y: 0.94), at: 1000.31)
        try e.tick(at: 1001)
        require(e.state.buttons.isEmpty && e.nextDeadline == nil && e.state.leftStick.y == 0.94,
                "Backing below the threshold cancels future A edges but keeps walking")
        try e.move(contact: 2, position: .init(x: 0, y: 1), at: 1001.1)
        require(e.state.buttons == [.a] && close(e.nextDeadline!, 1001.15), "Re-entering full forward begins a fresh repeat phase")
        e.recenterSticks()
        try e.tick(at: 1010)
        require(neutral(e) && e.nextDeadline == nil, "Re-center clears retained walking and all its future A repeats")

        for position in [StickPosition(x: 1, y: 0), .init(x: -1, y: 0), .init(x: 0, y: -1), .init(x: 1, y: 0.94)] {
            var directional = try engine()
            try directional.begin(contact: 1, control: move.id, position: position, at: 1234)
            try directional.tick(at: 1235)
            require(directional.state.buttons.isEmpty && directional.nextDeadline == nil,
                    "Direction(\(position.x),\(position.y)) does not activate forward-only A repeat")
        }
        var owners = try engine()
        try owners.begin(contact: 1, control: run.id, at: 2000)
        try owners.tick(at: 2000.5)
        try owners.end(contact: 1, at: 2000.51)
        try owners.begin(contact: 2, control: move.id, position: .init(x: 0, y: 1), at: 2000.6)
        try owners.tick(at: owners.nextDeadline!)
        require(owners.state.buttons == [.a] && owners.latchedControls.contains(run.id),
                "A repeat OFF edge cannot release the independently latched Run A")
        try owners.begin(contact: 3, control: run.id, at: 2000.66)
        try owners.end(contact: 3, at: 2000.67)
        require(owners.state.buttons.isEmpty && !owners.latchedControls.contains(run.id),
                "Tapping Run A off exposes the current repeat gap without stopping movement")
        try owners.tick(at: owners.nextDeadline!)
        require(owners.state.buttons == [.a], "A repeats resume normally after the independent latch is removed")
        try owners.begin(contact: 4, control: control("Reload B", on: "Walk").id, at: 2000.81)
        try owners.begin(contact: 5, control: center.id, at: 2000.82)
        require(owners.state.buttons == [.b] && owners.state.leftStick == .zero,
                "Center sticks cancels repeated A while preserving another finger's B")
        owners.releaseAll()
        try owners.tick(at: 2010)
        require(neutral(owners), "Global cleanup releases every remaining owner")

        for operation in ["cancel", "page", "releaseAll"] {
            var cancelled = try engine()
            try cancelled.begin(contact: 1, control: move.id, position: .init(x: 0, y: 1), at: 3000)
            if operation == "cancel" { try cancelled.handle(.cancel(contact: 1), at: 3000.05) }
            else if operation == "page" { _ = try cancelled.selectPage(page("Aim").id, at: 3000.05) }
            else { cancelled.releaseAll() }
            try cancelled.tick(at: 3100)
            require(neutral(cancelled) && cancelled.nextDeadline == nil,
                    "\(operation) clears the repeat before due work and no later edge revives it")
        }
        var delayed = try engine()
        try delayed.begin(contact: 1, control: move.id, position: .init(x: 0, y: 1), at: 4000)
        try delayed.tick(at: 4010)
        require(delayed.state.buttons.isEmpty && close(delayed.nextDeadline!, 4010.15),
                "A delayed timer releases once and preserves a full off gap instead of replaying missed presses")
        try delayed.tick(at: delayed.nextDeadline!)
        require(delayed.state.buttons == [.a] && close(delayed.nextDeadline!, 4010.2),
                "After a delayed timer, the next observed press has its full50ms duration")

        // The direct pad owns RS and both pressures only while touched. Existing
        // walking, its A repeat, an independent A latch, and held B remain separate.
        var aiming = try engine()
        try aiming.begin(contact: 1, control: run.id, at: 5000)
        try aiming.tick(at: 5000.5)
        try aiming.end(contact: 1, at: 5000.51)
        try aiming.begin(contact: 2, control: move.id, position: .init(x: 0, y: 1), at: 5000.6)
        try aiming.end(contact: 2, at: 5000.61)
        try aiming.begin(contact: 3, control: control("Reload B", on: "Walk").id, at: 5000.62)
        let aimSize = directAim.dimensions(for: .portrait)
        func aimSample(_ dx: Double = 0) -> ButtonPointerSample {
            .init(x: aimSize.width / 2 + dx, y: aimSize.height / 2,
                  width: aimSize.width, height: aimSize.height)
        }
        try aiming.handle(.beginButton(contact: 4, control: directAim.id, sample: aimSample()), at: 5000.63)
        require(close(aiming.practiceState.leftTrigger, 0.5) && close(aiming.practiceState.rightTrigger, 0.7) &&
                aiming.state.rightStick == .zero && aiming.state.leftStick.y == 1 &&
                aiming.state.buttons.isSuperset(of: [.a, .b]) && aiming.currentPageID == page("Walk").id,
                "Direct Aim begins LT50/RT70 on Walk without opening a ring, replacing movement or releasing other buttons")
        require(aiming.floatingRingStates.isEmpty && aiming.latchedControls.contains(run.id) &&
                !aiming.latchedControls.contains(directAim.id),
                "Direct Aim creates no ring or aim latch and preserves the independent Run latch")
        for (index, pair) in [(32.0, 0.5), (60, 1), (0, 0)].enumerated() {
            try aiming.handle(.moveButtonBatch(contact: 4, samples: [aimSample(pair.0)]), at: 5000.64 + Double(index) * 0.01)
            require(close(aiming.state.rightStick.x, pair.1) && aiming.state.rightStick.y == 0 &&
                    aiming.state.leftStick.y == 1 && close(aiming.practiceState.leftTrigger, 0.5) &&
                    close(aiming.practiceState.rightTrigger, 0.7) && aiming.state.buttons.isSuperset(of: [.a, .b]),
                    "Direct Aim drag\(pair.0) drives the expected RS value while preserving pressures and independent owners")
        }
        try aiming.handle(.moveButtonBatch(contact: 4, samples: [aimSample(32)]), at: 5000.67)
        for cleanup in ["lift", "cancel", "page", "releaseAll"] {
            var finished = aiming
            if cleanup == "lift" { try finished.handle(.endButton(contact: 4, finalSamples: []), at: 5000.68) }
            else if cleanup == "cancel" { try finished.handle(.cancel(contact: 4), at: 5000.68) }
            else if cleanup == "page" { _ = try finished.selectPage(page("Aim").id, at: 5000.68) }
            else { finished.releaseAll() }
            require(finished.practiceState.leftTrigger == 0 && finished.practiceState.rightTrigger == 0 && finished.state.rightStick == .zero,
                    "Direct Aim \(cleanup) releases both trigger pressures and centers RS")
            if cleanup == "lift" || cleanup == "cancel" {
                require(finished.state.leftStick.y == 1 && finished.state.buttons == [.a, .b] &&
                        finished.retainedSticks[move.id]?.y == 1 && finished.latchedControls.contains(run.id),
                        "Direct Aim \(cleanup) preserves retained movement, repeated A and independent A/B owners")
            } else {
                require(neutral(finished) && finished.retainedSticks.isEmpty && finished.latchedControls.isEmpty,
                        "Direct Aim \(cleanup) performs the expected global neutral cleanup")
            }
            try finished.tick(at: 5010)
            require(finished.practiceState.leftTrigger == 0 && finished.practiceState.rightTrigger == 0 &&
                    finished.state.rightStick == .zero && !finished.activeControls.contains(directAim.id),
                    "Direct Aim \(cleanup) cannot restart fire or aim after later timers")
        }
        require(try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])) == baselineData,
                "The baseline file remains byte-identical throughout verification")

        print("Profile SHA256: " + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        print("Scope: saved-profile preservation, reference geometry and actual core repeat behavior; no UIKit, phone or GTA6 game claim.")
        if failures.isEmpty { print("PASS: \(count) GTA 6 Prep supplemental checks.") }
        else { print("FAIL: \(failures.count) of \(count) GTA 6 Prep checks."); exit(1) }
    }
}
