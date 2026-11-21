import Foundation
import ControllerCore

// A separate native profile, never a replacement for the user's library.
// Portrait targets stay in the left half of the 337-point reference canvas.
func uid(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "17110000-0000-4000-8000-%012x", value))!
}
let walkID = uid(1), aimID = uid(2), driveID = uid(3), extrasID = uid(4), ringID = uid(5)
var profile = try ControllerProfile(id: uid(0), name: "GTA V - Left side", pages: [
    .init(id: walkID, name: "Walk"), .init(id: aimID, name: "Aim"),
    .init(id: driveID, name: "Drive"), .init(id: extrasID, name: "Extras")], homePageID: walkID)
var serial = 100
func add(_ page: UUID, _ name: String, _ x: Double, _ y: Double,
         width: Double = 48, height: Double = 44, payload: String? = nil,
         kind: ProfileControlKind = .button, toggle: Bool = false,
         aim: ButtonAimSettings = .init(), navigation: ProfilePageNavigation? = nil,
         action: FloatingLocalAction? = nil, retained: Bool = false) throws {
    let isStick = kind.isStick
    let c = ProfileControl(id: uid(serial), name: name, kind: kind,
        buttonBehavior: .init(holdToggle: toggle, holdMilliseconds: 500),
        stickBehavior: .init(autoCenter: !retained), payload: payload,
        swipeActivationEnabled: false, pageNavigation: navigation, buttonAim: aim,
        excludeFromCameraFollow: true,
        floatingAction: action.map { .init(action: $0, target: .zone(ringID)) },
        orientationDimensions: .init(portrait: .init(width: isStick ? 104 : width, height: isStick ? 104 : height),
                                     landscape: .init(width: isStick ? 104 : 64, height: isStick ? 104 : 44)))
    serial += 1
    try profile.addControl(c, toPage: page, portrait: .init(x: x / 337, y: y / 428))
}
func navigation(_ page: UUID, top: [(String, UUID)], bottom: (String, UUID)) throws {
    for (i, item) in top.enumerated() {
        try add(page, item.0, i == 0 ? 40 : 121, 24, width: 72, kind: .pageButton, navigation: .goTo(item.1))
    }
    try add(page, bottom.0, 40, 404, width: 72, kind: .pageButton, navigation: .goTo(bottom.1))
    try add(page, "Stop all", 121, 404, width: 72, payload: "RELEASE_ALL")
}

try navigation(walkID, top: [("Aim", aimID), ("Drive", driveID)], bottom: ("Extras", extrasID))
try add(walkID, "Move - stays", 116, 154, kind: .leftStick, retained: true)
try add(walkID, "Look", 116, 270, kind: .rightStick)
try add(walkID, "Center sticks", 116, 354, width: 104, kind: .recenter)
try add(walkID, "Weapons LB", 116, 76, width: 104, payload: "X360LB", toggle: true)
for (i, item) in [("Run A", "X360A"), ("Jump X", "X360X"), ("Car Y", "X360Y"),
                  ("Reload B", "X360B"), ("Cover RB", "X360RB")].enumerated() {
    try add(walkID, item.0, 28, Double(94 + i * 60), payload: item.1, toggle: i == 0)
}

try navigation(aimID, top: [("Walk", walkID), ("Drive", driveID)], bottom: ("Extras", extrasID))
try add(aimID, "Stop fire", 40, 300, width: 72, action: .stopFire)
try add(aimID, "Release aim", 121, 300, width: 72, action: .releaseADS)
try add(aimID, "Reload B", 40, 352, width: 72, payload: "X360B")
try add(aimID, "Center sticks", 121, 352, width: 72, kind: .recenter)
let ring = FloatingRingZone(id: ringID, name: "Move + aim ring",
    portraitGeometry: .init(canvasWidth: 337, canvasHeight: 428,
                            zone: .init(x: 56, y: 160, width: 56, height: 44)),
    landscapeGeometry: .init(canvasWidth: 494, canvasHeight: 208,
                             zone: .init(x: 56, y: 56, width: 44, height: 44)),
    config: .init(innerRadius: 32, movementRadius: 56,
        movement: .init(autoCenter: false, excludeFromCameraFollow: true, participateInBoosts: false),
        aim: .init(tuning: .init(output: .rightStick, fullDisplacement: 60, deadzone: 4)),
        knobs: [.init(id: "aim_1", name: "Aim + fire", targetDiameter: 44,
                      fire: .init(mode: .hold, adsPayload: "LT:0.5", firePayload: "RT:0.7",
                                  retainADSOnLift: true, retainFireOnLift: true))],
        boost1: .init(distance: 80, directInnerDistance: 80, directOuterDistance: 94),
        boost2: .init(distance: 108, directInnerDistance: 108, directOuterDistance: 124)))
profile.pages[1].floatingRingZones = [ring]

try navigation(driveID, top: [("Walk", walkID), ("Aim", aimID)], bottom: ("Extras", extrasID))
let steering = ButtonAimSettings(enabled: true,
    tuning: .init(output: .leftStick, fullDisplacement: 48, deadzone: 4, autoCenter: true))
for (i, item) in [("Drive 50%", "RT:0.5"), ("Drive 100%", "RT:1.0"),
                  ("Brake 35%", "LT:0.35"), ("Brake 100%", "LT:1.0")].enumerated() {
    try add(driveID, item.0, 116, Double(86 + i * 81), width: 104, height: 68,
            payload: item.1, aim: steering)
}
for (i, item) in [("Exit Y", "X360Y"), ("RB", "X360RB"), ("Aim LB", "X360LB"),
                  ("Horn LS", "X360LS"), ("Duck A", "X360A")].enumerated() {
    try add(driveID, item.0, 28, Double(94 + i * 60), payload: item.1)
}

try navigation(extrasID, top: [("Walk", walkID), ("Aim", aimID)], bottom: ("Drive", driveID))
let extras = [("D-pad up", "X360UP"), ("D-pad right", "X360RIGHT"),
              ("D-pad left", "X360LEFT"), ("D-pad down", "X360DOWN"),
              ("LS click", "X360LS"), ("RS click", "X360RS"),
              ("View", "X360BACK"), ("Menu", "X360START"),
              ("LT 25%", "LT:0.25"), ("RT 25%", "RT:0.25"),
              ("LT 100%", "LT:1.0"), ("RT 100%", "RT:1.0")]
for (i, item) in extras.enumerated() {
    try add(extrasID, item.0, i % 2 == 0 ? 40 : 121, Double(80 + (i / 2) * 52), width: 72, payload: item.1)
}

// Landscape is a separate spacious fallback. Portrait is the requested left-only layout.
for page in profile.pages {
    let controls = profile.controls(on: page.id)
    if page.id == walkID {
        var other = 0, stick = 0
        let slots: [(Double, Double)] = [(52,24),(164,24),(52,184),(164,184)] +
            [34.0,103,172].flatMap { y in [264.0,350,436].map { ($0,y) } }
        for c in controls {
            let point: (Double,Double)
            if c.kind.isStick { point = (stick == 0 ? 52 : 164,104); stick += 1 }
            else { point = slots[other]; other += 1 }
            try profile.move(c.id, to: .init(x: point.0 / 494, y: point.1 / 208), orientation: .landscape)
        }
    } else if page.id == driveID {
        var pad = 0, button = 0
        for c in controls {
            let point: (Double,Double)
            if c.buttonAim.enabled {
                point = (pad % 2 == 0 ? 54 : 166, pad < 2 ? 62 : 146); pad += 1
                let index = profile.controls.firstIndex(where: { $0.id == c.id })!
                profile.controls[index].orientationDimensions.landscape = .init(width: 104, height: 68)
            } else { point = ([264.0,350,436][button % 3], [34.0,103,172][button / 3]); button += 1 }
            try profile.move(c.id, to: .init(x: point.0 / 494, y: point.1 / 208), orientation: .landscape)
        }
    } else {
        for (i,c) in controls.enumerated() {
            let point: (Double,Double) = page.id == aimID
                ? ([264.0,350,436][i % 3], [34.0,103,172][i / 3])
                : ([55.0,182,309,436][i % 4], [26.0,78,130,182][i / 4])
            try profile.move(c.id, to: .init(x: point.0 / 494, y: point.1 / 208), orientation: .landscape)
        }
    }
}
try profile.validate()
let library = try ControllerProfileLibrary(activeProfileID: profile.id, profiles: [profile])
let bytes = try ControllerProfileLibraryCodec.encode(library)
guard CommandLine.arguments.count == 2 else { fatalError("Supply an output JSON path") }
try bytes.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
print("Created \(profile.name): \(profile.pages.count) pages, \(profile.controls.count) controls, \(bytes.count) bytes.")
