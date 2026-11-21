import Foundation
import CryptoKit
import Darwin
import ControllerCore

// Compile with the actual app models and a previously built ControllerCore module.
// This executable uses isolated defaults and a transport that never opens a socket.
@MainActor
private final class GTAProfileCheckTransport: BridgeTransporting {
    var onReady: (() -> Void)?
    var onMessage: ((Data) -> Void)?
    var onFailure: ((String) -> Void)?
    private(set) var opens = 0
    func open(host: String, port: UInt16) { opens += 1 }
    func send(_ data: Data) {}
    func close(afterSending stop: Data?) {}
}

@main
struct GTALeftProfileChecks {
    @MainActor
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "GTAProfileChecks", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Supply the generated GTA profile JSON path."])
        }
        var checks = 0
        var failures: [String] = []
        func require(_ condition: Bool, _ description: String) {
            checks += 1
            if !condition { failures.append(description); print("FAIL: \(description)") }
        }
        func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-10 }
        func overlaps(_ a: FloatingRect, _ b: FloatingRect) -> Bool {
            min(a.x + a.width, b.x + b.width) - max(a.x, b.x) > 1e-8 &&
            min(a.y + a.height, b.y + b.height) - max(a.y, b.y) > 1e-8
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let library = try ControllerProfileLibraryCodec.decode(data)
        let roundTrip = try ControllerProfileLibraryCodec.decode(ControllerProfileLibraryCodec.encode(library))
        require(roundTrip == library, "Native encode/decode preserves the complete profile")
        require(library.profiles.count == 1 && library.version == ControllerProfileLibrary.currentVersion,
                "Document decodes into one profile in the current native format")
        let profile = library.activeProfile
        require(profile.pages.map(\.name) == ["Walk", "Aim", "Drive", "Extras"] && profile.controls.count == 50,
                "Four named pages contain exactly 50 controls")
        require(profile.homePageID == profile.pages[0].id && profile.swipeMode == .off &&
                !profile.globalHoldEnabled && !profile.turboEnabled,
                "Walk is home; slide transfer, global Hold and global Turbo are off")
        require(profile.controls.allSatisfy { !$0.isTouchAim && !$0.isTouchpad && !$0.isCameraFollowAction },
                "The GTA profile does not require sensor TouchAim, desktop touchpads or Camera commands")
        func page(_ name: String) -> ProfilePage { profile.pages.first { $0.name == name }! }
        func control(_ name: String, on pageName: String) -> ProfileControl {
            profile.controls(on: page(pageName).id).first { $0.name == name }!
        }
        func engine(on pageName: String) throws -> ProfileInputEngine {
            var value = try ProfileInputEngine(profile: profile)
            _ = try value.selectPage(page(pageName).id, at: 0)
            return value
        }
        func neutral(_ e: ProfileInputEngine) -> Bool {
            e.state == .neutral && close(e.practiceState.leftTrigger, 0) && close(e.practiceState.rightTrigger, 0)
        }

        // Conservative rectangle bounds cover both round and rectangular touch targets.
        // These are the generated reference content areas, excluding the canvas header/footer.
        for (orientation, width, height) in [(ControllerOrientation.portrait, 337.0, 428.0),
                                             (.landscape, 494.0, 208.0)] {
            let usable = FloatingRect(x: 0, y: 0, width: width, height: height)
            for currentPage in profile.pages {
                let positions = Dictionary(uniqueKeysWithValues: profile.placements(for: orientation, on: currentPage.id).map { ($0.id, $0.position) })
                let frames = profile.controls(on: currentPage.id).map { c -> (String, FloatingRect) in
                    let size = c.dimensions(for: orientation), p = positions[c.id]!
                    return (c.name, .init(x: p.x * width - size.width / 2,
                                          y: p.y * height - size.height / 2, width: size.width, height: size.height))
                }
                let label = "\(currentPage.name) \(orientation)"
                require(frames.allSatisfy { usable.contains($0.1) }, "\(label): every target fits without edge clamping")
                require(frames.allSatisfy { $0.1.width >= 44 && $0.1.height >= 44 }, "\(label): every target is at least 44 points")
                var collisions: [String] = []
                for i in frames.indices { for j in frames.indices where j > i {
                    if overlaps(frames[i].1, frames[j].1) { collisions.append("\(frames[i].0)/\(frames[j].0)") }
                } }
                require(collisions.isEmpty, "\(label): no control overlap \(collisions.joined(separator: ", "))")
                if orientation == .portrait {
                    require(frames.allSatisfy { $0.1.x + $0.1.width <= width / 2 }, "\(label): every complete target stays in the left half")
                }
                for ring in currentPage.floatingRingZones {
                    let zone = try ring.geometry(for: orientation)!.resolved(canvasWidth: width, canvasHeight: height)
                    let geometry = try FloatingRingGeometry(config: ring.config)
                    require(usable.contains(zone) && frames.allSatisfy { !overlaps(zone, $0.1) }, "\(label): ring activation area fits and avoids controls")
                    let points = [zone.center, FloatingPoint(x: zone.x, y: zone.y),
                                  .init(x: zone.x + zone.width, y: zone.y),
                                  .init(x: zone.x, y: zone.y + zone.height),
                                  .init(x: zone.x + zone.width, y: zone.y + zone.height)]
                    for (index, point) in points.enumerated() {
                        let placement = geometry.place(at: point, usable: usable)
                        require(placement != nil, "\(label): ring can spawn at sample \(index)")
                        guard let placement else { continue }
                        require(usable.contains(placement.bounds) && frames.allSatisfy { !overlaps(placement.bounds, $0.1) },
                                "\(label): spawned ring and Finish tab avoid controls at sample \(index)")
                        if orientation == .portrait {
                            require(placement.bounds.x + placement.bounds.width <= width / 2,
                                    "\(label): spawned ring and Finish tab stay in the left half at sample \(index)")
                        }
                    }
                }
            }
        }

        // Actual advanced-button engine: each pressure pad steers with the same finger.
        let pads = profile.controls(on: page("Drive").id).filter { $0.buttonAim.enabled }
        require(pads.count == 4, "Drive has four combined pressure/steering pads")
        let pressures: [String: (Double, Double)] = ["Drive 50%": (0, 0.5), "Drive 100%": (0, 1),
                                                   "Brake 35%": (0.35, 0), "Brake 100%": (1, 0)]
        for pad in pads {
            guard let expected = pressures[pad.name] else {
                require(false, "Unexpected driving pad \(pad.name)"); continue
            }
            var e = try engine(on: "Drive")
            let size = pad.dimensions(for: .portrait)
            func pointer(_ dx: Double = 0, _ dy: Double = 0) -> ButtonPointerSample {
                .init(x: size.width / 2 + dx, y: size.height / 2 + dy, width: size.width, height: size.height)
            }
            try e.handle(.beginButton(contact: 1, control: pad.id, sample: pointer()), at: 0)
            require(close(e.practiceState.leftTrigger, expected.0) && close(e.practiceState.rightTrigger, expected.1) && e.state.leftStick == .zero,
                    "\(pad.name): initial contact sends only its configured pressure")
            for (index, dx) in [-48.0, 48, 0].enumerated() {
                try e.handle(.moveButtonBatch(contact: 1, samples: [pointer(dx)]), at: Double(index + 1) / 10)
                require(close(e.state.leftStick.x, dx / 48) && close(e.state.leftStick.y, 0) && e.state.rightStick == .zero &&
                        close(e.practiceState.leftTrigger, expected.0) && close(e.practiceState.rightTrigger, expected.1),
                        "\(pad.name): steering \(dx) preserves pressure and does not drive RS")
            }
            try e.handle(.endButton(contact: 1, finalSamples: []), at: 0.4)
            require(neutral(e), "\(pad.name): lifting releases both steering and pressure")
            try e.handle(.beginButton(contact: 2, control: pad.id, sample: pointer()), at: 0.5)
            try e.handle(.cancel(contact: 2), at: 0.6)
            try e.tick(at: 5)
            require(neutral(e), "\(pad.name): cancellation remains neutral after later timers")
        }

        // One-finger walking: retained movement, independent toggles and centered look.
        var walk = try engine(on: "Walk")
        let move = control("Move - stays", on: "Walk"), look = control("Look", on: "Walk")
        let run = control("Run A", on: "Walk"), weapons = control("Weapons LB", on: "Walk")
        try walk.handle(.begin(contact: 1, control: move.id, position: .init(x: 0.25, y: 0.8)), at: 0)
        try walk.handle(.end(contact: 1), at: 0.05)
        require(walk.state.leftStick == .init(x: 0.25, y: 0.8), "Walk movement stays after lift")
        try walk.handle(.begin(contact: 2, control: run.id, position: .zero), at: 0.1)
        try walk.tick(at: 0.6); try walk.handle(.end(contact: 2), at: 0.61)
        require(walk.state.buttons.contains(.a) && walk.latchedControls.contains(run.id) && walk.state.leftStick.y == 0.8,
                "Run A latches after its 500 ms hold while movement continues")
        try walk.handle(.begin(contact: 3, control: weapons.id, position: .zero), at: 0.7)
        try walk.tick(at: 1.2); try walk.handle(.end(contact: 3), at: 1.21)
        require(walk.state.buttons == [.a, .leftBumper] && walk.latchedControls.contains(weapons.id),
                "Weapons LB can latch independently alongside Run A")
        try walk.handle(.begin(contact: 4, control: look.id, position: .init(x: 0.5, y: -0.2)), at: 1.3)
        require(walk.state.rightStick == .init(x: 0.5, y: -0.2) && walk.state.leftStick.y == 0.8,
                "Look drives RS without replacing retained movement")
        try walk.handle(.end(contact: 4), at: 1.4)
        require(walk.state.rightStick == .zero && walk.state.leftStick.y == 0.8, "Look centers on lift while movement stays")
        try walk.handle(.begin(contact: 5, control: control("Center sticks", on: "Walk").id, position: .zero), at: 1.5)
        try walk.handle(.end(contact: 5), at: 1.51)
        require(walk.state.leftStick == .zero && walk.state.rightStick == .zero && walk.state.buttons == [.a, .leftBumper],
                "Center sticks clears movement without unexpectedly releasing independent button holds")
        try walk.handle(.begin(contact: 6, control: weapons.id, position: .zero), at: 1.6)
        try walk.handle(.end(contact: 6), at: 1.61)
        require(walk.state.buttons == [.a], "Tapping held Weapons LB releases only Weapons")
        try walk.handle(.begin(contact: 7, control: control("Stop all", on: "Walk").id, position: .zero), at: 1.7)
        require(neutral(walk) && walk.latchedControls.isEmpty && walk.retainedSticks.isEmpty,
                "Stop all clears walking and all latched buttons")

        // Actual ring state machine: movement retention + aim/fire + scoped safety controls.
        var aim = try engine(on: "Aim")
        let ring = page("Aim").floatingRingZones[0], session = UUID()
        let usable = FloatingRect(x: 0, y: 0, width: 337, height: 428)
        let zone = try ring.portraitGeometry!.resolved(canvasWidth: usable.width, canvasHeight: usable.height)
        try aim.handle(.beginFloatingRing(contact: 1, zoneID: ring.id, sessionID: session, point: zone.center, usable: usable), at: 0)
        require(aim.floatingRingStates[ring.id]?.visible == true, "Aim ring summons from its activation area")
        func ringPoint(_ e: ProfileInputEngine, dx: Double = 0, dy: Double = 0) -> FloatingPoint {
            let s = e.floatingRingStates[ring.id]!
            return .init(x: s.placement.origin.x + s.geometry.center.x + dx,
                         y: s.placement.origin.y + s.geometry.center.y + dy)
        }
        try aim.handle(.moveFloatingRing(contact: 1, sessionID: session, samples: [.init(point: ringPoint(aim, dy: -40), elapsed: 0.1)]), at: 0.1)
        try aim.handle(.endFloatingRing(contact: 1, sessionID: session, samples: []), at: 0.2)
        let retainedMovement = aim.state.leftStick
        require(retainedMovement.y > 0.5 && aim.floatingRingStates[ring.id]?.retained == true,
                "Ring movement stays after lifting")
        try aim.handle(.beginFloatingRing(contact: 2, zoneID: ring.id, sessionID: session, point: ringPoint(aim), usable: usable), at: 0.3)
        require(close(aim.practiceState.leftTrigger, 0.5) && close(aim.practiceState.rightTrigger, 0.7),
                "Aim + fire emits the configured LT 50% / RT 70% requests")
        try aim.handle(.moveFloatingRing(contact: 2, sessionID: session, samples: [.init(point: ringPoint(aim, dx: 20), elapsed: 0.1)]), at: 0.4)
        require(aim.state.rightStick.x > 0 && aim.state.leftStick == retainedMovement,
                "Ring aiming uses RS while retained LS movement remains")
        try aim.handle(.endFloatingRing(contact: 2, sessionID: session, samples: []), at: 0.5)
        require(close(aim.practiceState.leftTrigger, 0.5) && close(aim.practiceState.rightTrigger, 0.7) && aim.state.rightStick == .zero,
                "Ring lift retains trigger requests and centers aim")
        var centeredAim = aim
        try centeredAim.handle(.begin(contact: 5, control: control("Center sticks", on: "Aim").id, position: .zero), at: 0.55)
        try centeredAim.handle(.end(contact: 5), at: 0.56)
        require(centeredAim.state.leftStick == .zero && centeredAim.state.rightStick == .zero &&
                close(centeredAim.practiceState.leftTrigger, 0.5) && close(centeredAim.practiceState.rightTrigger, 0.7),
                "Aim Center sticks stops retained movement without clearing ADS/fire")
        try aim.handle(.begin(contact: 3, control: control("Stop fire", on: "Aim").id, position: .zero), at: 0.6)
        try aim.handle(.end(contact: 3), at: 0.61)
        require(close(aim.practiceState.leftTrigger, 0.5) && close(aim.practiceState.rightTrigger, 0) && aim.state.leftStick == retainedMovement,
                "Stop fire releases RT only and preserves movement/ADS")
        try aim.handle(.begin(contact: 4, control: control("Release aim", on: "Aim").id, position: .zero), at: 0.7)
        try aim.handle(.end(contact: 4), at: 0.71)
        require(close(aim.practiceState.leftTrigger, 0) && close(aim.practiceState.rightTrigger, 0) && aim.state.leftStick == retainedMovement,
                "Release aim releases LT without silently recentering movement")
        try aim.handle(.floatingRingAction(zoneID: ring.id, sessionID: session, action: .finish), at: 0.8)
        require(neutral(aim) && aim.floatingRingStates[ring.id]?.finished == true,
                "Finish ends the ring and all of its retained output")
        try aim.tick(at: 10)
        require(neutral(aim), "Finished ring does not revive after time advances")

        // Exercise the app's actual additive import, including fresh local references.
        let suite = "SimpleController.GTAProfileChecks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let initial = ControllerProfileLibrary.default
        defaults.set(try ControllerProfileLibraryCodec.encode(initial), forKey: ProfileControllerViewModel.libraryKey)
        let preserved = Data("synthetic recovery bytes".utf8)
        defaults.set(preserved, forKey: "controller.profiles.before-format-5")
        let transport = GTAProfileCheckTransport()
        let archiveURL = FileManager.default.temporaryDirectory.appendingPathComponent("GTAProfileChecks-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: archiveURL) }
        let model = ProfileControllerViewModel(defaults: defaults, transport: transport, clock: { 0 },
                                              automaticTimer: false, persistSettings: true, androidArchiveDirectory: archiveURL)
        require(model.importProfiles(data), "Actual app model imports the generated document")
        require(model.library.profiles.count == 2 && model.library.profiles[0] == initial.activeProfile &&
                model.library.activeProfileID == initial.activeProfileID,
                "Import adds a profile without altering the existing profile or selection")
        let imported = model.library.profiles.last!
        require(imported.id != profile.id && Set(imported.controls.map(\.id)).isDisjoint(with: Set(profile.controls.map(\.id))) &&
                Set(imported.pages.map(\.id)).isDisjoint(with: Set(profile.pages.map(\.id))),
                "Import gives the profile, pages and controls fresh identities")
        let importedRing = imported.pages.first { $0.name == "Aim" }!.floatingRingZones[0]
        require(importedRing.id != ring.id && imported.controls.filter { $0.floatingAction != nil }.allSatisfy {
            $0.floatingAction?.target == .zone(importedRing.id)
        }, "Imported local ring actions target the copied ring, not the source IDs")
        require(model.selectProfile(imported.id), "Imported GTA profile can be selected")
        for p in imported.pages {
            model.selectPage(p.id)
            require(!model.hasCameraFollowOutputs && !model.hasDesktopOutputs,
                    "\(p.name): no Camera/desktop capability or extra Camera row is needed")
        }
        require(model.importProfiles(data) && model.library.profiles.count == 3 && model.profile.id == imported.id,
                "Repeated import remains additive and preserves the selected GTA copy")
        require(Set(model.library.profiles.map(\.name)).count == 3 && defaults.data(forKey: "controller.profiles.before-format-5") == preserved,
                "Repeated imports have distinct names and preserve older recovery bytes")
        let persisted = try ControllerProfileLibraryCodec.decode(defaults.data(forKey: ProfileControllerViewModel.libraryKey)!)
        require(persisted == model.library, "Imported library persists exactly")
        let archiveContents = try FileManager.default.contentsOfDirectory(atPath: archiveURL.path)
        require(archiveContents.isEmpty && model.library.androidSources.isEmpty && transport.opens == 0,
                "Native import creates no source archives and never opens a network transport")

        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        print("Profile SHA256: \(digest)")
        print("Scope: actual core + app import model; reference geometry only, no UIKit/phone/Xbox verification.")
        if failures.isEmpty { print("PASS: \(checks) GTA left-side profile checks.") }
        else {
            print("FAIL: \(failures.count) of \(checks) GTA checks failed.")
            exit(1)
        }
    }
}
