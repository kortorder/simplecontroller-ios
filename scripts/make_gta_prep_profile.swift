import Foundation
import ControllerCore

// Derive a separate additive profile from the verified GTA V layout. The input
// document is read-only; native import gives this new profile another fresh set
// of identities, so neither existing phone profile is replaced.
guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: make_gta_prep_profile BASELINE_JSON OUTPUT_JSON")
}
let baselineURL = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
guard baselineURL != outputURL else { fatalError("The output must not replace the baseline profile.") }
let baselineData = try Data(contentsOf: baselineURL)
let baselineLibrary = try ControllerProfileLibraryCodec.decode(baselineData)
guard baselineLibrary.profiles.count == 1,
      baselineLibrary.activeProfile.name == "GTA V - Left side" else {
    fatalError("Expected the verified single-profile GTA V - Left side document.")
}
var profile = try baselineLibrary.activeProfile.cloned(name: "GTA 6 Prep")

func pageID(_ name: String) -> UUID {
    guard let page = profile.pages.first(where: { $0.name == name }) else { fatalError("Missing page: \(name)") }
    return page.id
}
func controlIndex(_ name: String, on page: String) -> Int {
    let ids = Set(profile.pages.first(where: { $0.id == pageID(page) })!.controlIDs)
    guard let index = profile.controls.firstIndex(where: { ids.contains($0.id) && $0.name == name }) else {
        fatalError("Missing control: \(page) / \(name)")
    }
    return index
}
func movePortrait(_ name: String, on page: String, x: Double, y: Double) {
    let id = profile.controls[controlIndex(name, on: page)].id
    let index = profile.portrait.firstIndex(where: { $0.id == id })!
    // Replace in place: preserve the original drawing order and all landscape geometry.
    profile.portrait[index] = .init(id: id, position: .init(x: x / 337, y: y / 428))
}

// Two 104-point sticks stack near the left edge. The nearby buttons occupy
// the space the sticks vacate; the original top-row positions, Weapons and Run stay.
movePortrait("Move - stays", on: "Walk", x: 56, y: 366)
movePortrait("Look", on: "Walk", x: 56, y: 250)
movePortrait("Extras", on: "Walk", x: 40, y: 142)
movePortrait("Stop all", on: "Walk", x: 121, y: 142)
for (name, y) in [("Jump X", 194.0), ("Car Y", 246), ("Reload B", 298),
                  ("Cover RB", 350), ("Center sticks", 402)] {
    movePortrait(name, on: "Walk", x: 141, y: y)
}
// Full forward requests repeated A: 50 ms on, 150 ms off, starting immediately.
// The game must map that input as desired; this is preparation, not GTA 6 validation.
// The existing Run A toggle remains independent and must be off for visible gaps.
let moveIndex = controlIndex("Move - stays", on: "Walk")
profile.controls[moveIndex].stickBehavior.stickPlusEnabled = true
profile.controls[moveIndex].stickBehavior.superBoostThreshold = 0.95
profile.controls[moveIndex].stickBehavior.directions[.up] = .init(superBoostControls: [.a])
profile.controls[moveIndex].stickPlusRepeatIntervalMilliseconds = 200

// The former Walk → Aim shortcut becomes a direct, momentary aiming pad in
// exactly the same position and size. The ring page remains available through
// the page selector and the other pages' existing Aim shortcuts.
let directAimIndex = controlIndex("Aim", on: "Walk")
profile.controls[directAimIndex].name = "Aim + fire"
profile.controls[directAimIndex].kind = .button
profile.controls[directAimIndex].pageNavigation = nil
profile.controls[directAimIndex].payload = "LT:0.5,RT:0.7"
profile.controls[directAimIndex].buttonAim = .init(enabled: true,
    tuning: .init(output: .rightStick, fullDisplacement: 60, deadzone: 4, autoCenter: true))

// Keep the comfortable ring's exact behavior and dimensions. All activation
// points clamp its full 112×160 footprint, including Finish, to (0,268).
for (name, x, y) in [("Stop fire", 40.0, 76.0), ("Release aim", 121, 76),
                     ("Reload B", 40, 128), ("Center sticks", 121, 128),
                     ("Extras", 40, 180), ("Stop all", 121, 180)] {
    movePortrait(name, on: "Aim", x: x, y: y)
}
let aimPageIndex = profile.pages.firstIndex(where: { $0.id == pageID("Aim") })!
guard profile.pages[aimPageIndex].floatingRingZones.count == 1 else { fatalError("Expected one Aim ring.") }
profile.pages[aimPageIndex].floatingRingZones[0].portraitGeometry = .init(
    canvasWidth: 337, canvasHeight: 428, zone: .init(x: 4, y: 372, width: 48, height: 44))

// Square orientation dimensions with no shared rectangle override render as
// circles in ProfileCanvas. Keep every center and full name; preserve the two
// sticks, all five Button Aim drag surfaces and the complete ring geometry.
for index in profile.controls.indices where !profile.controls[index].kind.isStick && !profile.controls[index].buttonAim.enabled {
    guard profile.controls[index].controlWidth == nil && profile.controls[index].controlHeight == nil else {
        fatalError("Unexpected shared rectangle override on an ordinary control.")
    }
    profile.controls[index].orientationDimensions = .init(
        portrait: .init(width: 44, height: 44), landscape: .init(width: 44, height: 44))
}

try profile.validate()
let library = try ControllerProfileLibrary(activeProfileID: profile.id, profiles: [profile])
let data = try ControllerProfileLibraryCodec.encode(library)
guard try ControllerProfileLibraryCodec.decode(data) == library else { fatalError("Profile round-trip failed.") }
try data.write(to: outputURL, options: .atomic)
guard try Data(contentsOf: baselineURL) == baselineData else { fatalError("Baseline unexpectedly changed.") }
print("Created \(profile.name): native format \(library.version), \(profile.pages.count) pages, \(profile.controls.count) controls, \(data.count) bytes.")
