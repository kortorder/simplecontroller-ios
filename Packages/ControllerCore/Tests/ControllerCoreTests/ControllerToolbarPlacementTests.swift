import Foundation
import XCTest
@testable import ControllerCore

final class ControllerToolbarPlacementTests: XCTestCase {
    func testPortraitToolbarStaysWithinSafeAreaAtEveryCorner() {
        let g = ControllerToolbarGeometry(screenWidth: 393, screenHeight: 852, safeTop: 59, safeBottom: 34,
                                          safeLeft: 0, safeRight: 0, requestedWidth: 300, requestedHeight: 180)
        for x in [0.0, 0.5, 1.0] {
            for y in [0.0, 0.5, 1.0] {
                let p = g.center(for: .init(x: x, y: y))
                XCTAssertGreaterThanOrEqual(p.x - g.width / 2, 8)
                XCTAssertLessThanOrEqual(p.x + g.width / 2, 385)
                XCTAssertGreaterThanOrEqual(p.y - g.height / 2, 67)
                XCTAssertLessThanOrEqual(p.y + g.height / 2, 810)
            }
        }
    }
    func testLandscapeAndHugeTextCannotPushHandleOffScreen() {
        let g = ControllerToolbarGeometry(screenWidth: 852, screenHeight: 393, safeTop: 0, safeBottom: 21,
                                          safeLeft: 59, safeRight: 59, requestedWidth: 900, requestedHeight: 1600)
        XCTAssertEqual(g.width, 718); XCTAssertEqual(g.height, 356)
        XCTAssertEqual(g.travelX, 0); XCTAssertEqual(g.travelY, 0)
        XCTAssertEqual(g.center(for: .init(x: 1, y: 1)).y - g.height / 2, 8)
    }
    func testDragClampsAndTracksNormalizedTravel() {
        let g = ControllerToolbarGeometry(screenWidth: 400, screenHeight: 800, safeTop: 0, safeBottom: 0,
                                          safeLeft: 0, safeRight: 0, requestedWidth: 200, requestedHeight: 100)
        XCTAssertEqual(g.moved(.init(x: 0, y: 0), dx: 92, dy: 342), .init(x: 0.5, y: 0.5))
        XCTAssertEqual(g.moved(.init(x: 0.5, y: 0.5), dx: -10000, dy: 10000), .init(x: 0, y: 1))
    }
    func testZeroTravelKeepsAnchorForLargerScreens() {
        let g = ControllerToolbarGeometry(screenWidth: 100, screenHeight: 100, safeTop: 0, safeBottom: 0,
                                          safeLeft: 0, safeRight: 0, requestedWidth: 100, requestedHeight: 100)
        XCTAssertEqual(g.moved(.init(x: 0.2, y: 0.8), dx: 100, dy: -100), .init(x: 0.2, y: 0.8))
    }
    func testBadGeometryNeverProducesNonfiniteValues() {
        let g = ControllerToolbarGeometry(screenWidth: .nan, screenHeight: -.infinity, safeTop: 400, safeBottom: .nan,
                                          safeLeft: .infinity, safeRight: 0, requestedWidth: .nan, requestedHeight: 12)
        XCTAssertEqual(g.width, 0); XCTAssertEqual(g.height, 0)
        XCTAssertTrue(g.center(for: .init(x: .nan, y: .infinity)).x.isFinite)
    }
    func testHeightChangeKeepsBottomDocked() {
        for height in [60.0, 120, 900] {
            let g = ControllerToolbarGeometry(screenWidth: 393, screenHeight: 852, safeTop: 59, safeBottom: 34,
                                              safeLeft: 0, safeRight: 0, requestedWidth: 200, requestedHeight: height)
            XCTAssertEqual(g.center(for: .init(x: 0, y: 1)).y + g.height / 2, 810)
        }
    }
    func testPositionsPersistIndependentlyAndResetWithoutProfiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("toolbar-positions.json")
        let store = ControllerToolbarPositionStore(url: url)
        XCTAssertEqual(try store.load(), [:]); XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        let values: [String: ControllerToolbarAnchor] = ["actions.portrait": .init(x: 0, y: 0), "actions.landscape": .init(x: 1, y: 0.4), "tools.portrait": .init(x: 0.8, y: 1)]
        try store.save(values)
        XCTAssertEqual(try ControllerToolbarPositionStore(url: url).load(), values)
        try store.save([:]); XCTAssertEqual(try store.load(), [:])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["toolbar-positions.json"])
    }
    func testCorruptOldSettingsGetExactRecoveryBeforeReplacement() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("toolbar-positions.json"), bytes = Data("broken settings".utf8)
        try bytes.write(to: url)
        let store = ControllerToolbarPositionStore(url: url)
        XCTAssertThrowsError(try store.load())
        try store.save(["actions.portrait": .init(x: 0, y: 1)])
        let recovery = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.contains("recovery") }
        XCTAssertEqual(recovery.count, 1); XCTAssertEqual(try Data(contentsOf: XCTUnwrap(recovery.first)), bytes)
        XCTAssertEqual(try store.load(), ["actions.portrait": .init(x: 0, y: 1)])
    }
    func testMalformedDecodedAnchorIsRejectedInsteadOfSilentlyClamped() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("toolbar-positions.json")
        try Data(#"{"version":1,"positions":{"actions.portrait":{"x":2,"y":0}}}"#.utf8).write(to: url)
        XCTAssertThrowsError(try ControllerToolbarPositionStore(url: url).load())
    }
    func testFailedSaveDoesNotCreateOrChangeProfileFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let profiles = folder.appendingPathComponent("library.json"), bytes = Data("untouched profile bytes".utf8)
        try bytes.write(to: profiles)
        let store = ControllerToolbarPositionStore(url: profiles.appendingPathComponent("impossible.json"))
        XCTAssertThrowsError(try store.save([:]))
        XCTAssertEqual(try Data(contentsOf: profiles), bytes)
    }

    func testOldPositionDocumentDefaultsToHorizontalAndSurvivesStyleUpdate() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("toolbar-positions.json")
        let old = Data(#"{"version":1,"positions":{"actions.portrait":{"x":0.2,"y":0.7},"actions.landscape":{"x":1,"y":0}}}"#.utf8)
        try old.write(to: url)
        let store = ControllerToolbarPositionStore(url: url)
        let expected = ["actions.portrait": ControllerToolbarAnchor(x: 0.2, y: 0.7), "actions.landscape": .init(x: 1, y: 0)]
        XCTAssertEqual(try store.loadSettings(), .init(positions: expected))
        XCTAssertEqual(try Data(contentsOf: url), old)
        try store.saveVertical(true, for: "actions")
        XCTAssertEqual(try ControllerToolbarPositionStore(url: url).loadSettings(), .init(positions: expected, verticalToolbars: ["actions": true]))
    }

    func testRepositionAndResetPreserveGlobalStyleAcrossOrientations() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("toolbar-positions.json"), store = ControllerToolbarPositionStore(url: url)
        try store.saveVertical(true, for: "actions")
        try store.saveVertical(false, for: "other")
        let moved = ["actions.portrait": ControllerToolbarAnchor(x: 0, y: 0.5), "actions.landscape": .init(x: 1, y: 1)]
        try store.save(moved)
        XCTAssertEqual(try store.loadSettings(), .init(positions: moved, verticalToolbars: ["actions": true, "other": false]))
        try store.save([:])
        XCTAssertEqual(try ControllerToolbarPositionStore(url: url).loadSettings(), .init(verticalToolbars: ["actions": true, "other": false]))
        try store.saveVertical(false, for: "actions")
        XCTAssertEqual(try store.loadSettings().verticalToolbars, ["actions": false, "other": false])
    }

    func testStyleMapRequiresActualBooleansAndBoundedIdentifiers() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("toolbar-positions.json"), store = ControllerToolbarPositionStore(url: url)
        for raw in [#"{"actions":1}"#, #"{"actions":"true"}"#, #"{"actions":null}"#, #"[]"#] {
            let bytes = Data("{\"version\":1,\"positions\":{},\"verticalToolbars\":\(raw)}".utf8)
            try bytes.write(to: url)
            XCTAssertThrowsError(try store.loadSettings())
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
        try store.saveSettings(.init(verticalToolbars: ["actions": true]))
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(try store.saveVertical(false, for: ""))
        XCTAssertThrowsError(try store.saveVertical(false, for: String(repeating: "x", count: 101)))
        let tooMany = Dictionary(uniqueKeysWithValues: (0...32).map { ("toolbar\($0)", true) })
        XCTAssertThrowsError(try store.saveSettings(.init(verticalToolbars: tooMany)))
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testFailedStyleWriteRestoresExactPreviousSettings() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("toolbar-positions.json"), store = ControllerToolbarPositionStore(url: url)
        let original = ControllerToolbarSettings(positions: ["actions.portrait": .init(x: 0.4, y: 0.8)], verticalToolbars: ["actions": false])
        try store.saveSettings(original)
        let before = try Data(contentsOf: url)
        let failing = ControllerToolbarPositionStore(url: url) { _, path in
            try Data("incomplete write".utf8).write(to: path)
            throw NSError(domain: "Forced toolbar write failure", code: 1)
        }
        XCTAssertThrowsError(try failing.saveVertical(true, for: "actions"))
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(try ControllerToolbarPositionStore(url: url).loadSettings(), original)
    }

    func testSilentBadStyleWriteFailsVerificationAndRestoresPreviousBytes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("toolbar-positions.json"), store = ControllerToolbarPositionStore(url: url)
        try store.saveVertical(true, for: "actions")
        let before = try Data(contentsOf: url)
        let failing = ControllerToolbarPositionStore(url: url) { _, path in try Data("not the requested bytes".utf8).write(to: path) }
        XCTAssertThrowsError(try failing.saveVertical(false, for: "actions"))
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(try store.loadSettings().verticalToolbars, ["actions": true])
    }

    func testStyleChangeBacksUpMalformedOldDocumentExactly() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("toolbar-positions.json"), before = Data("damaged toolbar data".utf8)
        try before.write(to: url)
        let store = ControllerToolbarPositionStore(url: url)
        try store.saveVertical(true, for: "actions")
        let recoveries = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.contains("recovery") }
        XCTAssertEqual(recoveries.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(recoveries.first)), before)
        XCTAssertEqual(try store.loadSettings(), .init(verticalToolbars: ["actions": true]))
    }

    func testLegacySettingsWithoutMinimizedFlagKeepTopMenuExpanded() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("toolbar-positions.json")
        let old = Data(#"{"version":1,"positions":{"actions.portrait":{"x":0.3,"y":1}},"verticalToolbars":{"actions":true}}"#.utf8)
        try old.write(to: url)
        let expected = ControllerToolbarSettings(positions: ["actions.portrait": .init(x: 0.3, y: 1)], verticalToolbars: ["actions": true])
        XCTAssertEqual(try ControllerToolbarPositionStore(url: url).loadSettings(), expected)
        XCTAssertEqual(try Data(contentsOf: url), old)
    }

    func testMinimizedFlagPersistsThroughCircleMoveStyleChangeAndPositionReset() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("toolbar-positions.json"), store = ControllerToolbarPositionStore(url: url)
        let initial = ControllerToolbarSettings(positions: ["actions.portrait": .init(x: 0.3, y: 1)], verticalToolbars: ["actions": true])
        try store.saveSettings(initial)
        try store.saveTopMenuMinimized(true)
        var expected = initial; expected.topMenuMinimized = true
        XCTAssertEqual(try ControllerToolbarPositionStore(url: url).loadSettings(), expected)
        var moved = initial.positions
        moved["menuButton.portrait"] = .init(x: 0, y: 0.4)
        moved["menuButton.landscape"] = .init(x: 1, y: 1)
        try store.save(moved)
        try store.saveVertical(false, for: "actions")
        XCTAssertEqual(try store.loadSettings(), .init(positions: moved, verticalToolbars: ["actions": false], topMenuMinimized: true))
        try store.save([:])
        XCTAssertEqual(try store.loadSettings(), .init(verticalToolbars: ["actions": false], topMenuMinimized: true))
        try store.save(moved)
        try store.saveTopMenuMinimized(false)
        XCTAssertEqual(try ControllerToolbarPositionStore(url: url).loadSettings(), .init(positions: moved, verticalToolbars: ["actions": false]))
    }

    func testMinimizedFlagRequiresAnActualBoolean() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("toolbar-positions.json"), store = ControllerToolbarPositionStore(url: url)
        for raw in ["1", #""true""#, "[]", "{}"] {
            let bytes = Data("{\"version\":1,\"positions\":{},\"topMenuMinimized\":\(raw)}".utf8)
            try bytes.write(to: url)
            XCTAssertThrowsError(try store.loadSettings())
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }

    func testFailedMinimizeWriteKeepsExactExpandedSettingsAndAllOtherChoices() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("toolbar-positions.json"), store = ControllerToolbarPositionStore(url: url)
        let original = ControllerToolbarSettings(positions: ["menuButton.portrait": .init(x: 0.4, y: 0.2)], verticalToolbars: ["actions": true])
        try store.saveSettings(original)
        let before = try Data(contentsOf: url)
        let failing = ControllerToolbarPositionStore(url: url) { _, path in
            try Data("partial minimize save".utf8).write(to: path)
            throw NSError(domain: "Forced minimize write failure", code: 1)
        }
        XCTAssertThrowsError(try failing.saveTopMenuMinimized(true))
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(try store.loadSettings(), original)
    }

    func testBuild37SettingsDefaultActionsExpandedWithoutChangingTopMenu() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("toolbar-positions.json")
        let old = Data(#"{"version":1,"positions":{"menuButton.portrait":{"x":0.3,"y":0.2}},"verticalToolbars":{"actions":true},"topMenuMinimized":true}"#.utf8)
        try old.write(to: url)
        let expected = ControllerToolbarSettings(positions: ["menuButton.portrait": .init(x: 0.3, y: 0.2)], verticalToolbars: ["actions": true], topMenuMinimized: true)
        XCTAssertEqual(try ControllerToolbarPositionStore(url: url).loadSettings(), expected)
        XCTAssertEqual(try Data(contentsOf: url), old)
    }

    func testBothMenuMinimizedChoicesPersistIndependently() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("toolbar-positions.json"), store = ControllerToolbarPositionStore(url: url)
        let circles = ["menuButton.portrait": ControllerToolbarAnchor(x: 0.1, y: 0.2), "actionsMenuButton.portrait": .init(x: 0.8, y: 0.9)]
        try store.save(circles)
        for top in [true, false] {
            try store.saveTopMenuMinimized(top)
            for actions in [true, false] {
                try store.saveActionsMenuMinimized(actions)
                XCTAssertEqual(try ControllerToolbarPositionStore(url: url).loadSettings(), .init(positions: circles, topMenuMinimized: top, actionsMenuMinimized: actions))
            }
        }
        try store.saveActionsMenuMinimized(true)
        try store.saveTopMenuMinimized(true)
        try store.saveTopMenuMinimized(false)
        XCTAssertTrue(try store.loadSettings().actionsMenuMinimized)
    }

    func testCirclePositionStyleAndResetPreserveBothMenuChoices() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("toolbar-positions.json"), store = ControllerToolbarPositionStore(url: url)
        try store.saveTopMenuMinimized(true)
        try store.saveActionsMenuMinimized(true)
        try store.saveVertical(true, for: "actions")
        let circles = ["menuButton.portrait": ControllerToolbarAnchor(x: 0.1, y: 0.2),
                       "actionsMenuButton.portrait": .init(x: 0.8, y: 0.9), "actionsMenuButton.landscape": .init(x: 1, y: 1)]
        try store.save(circles)
        XCTAssertEqual(try store.loadSettings(), .init(positions: circles, verticalToolbars: ["actions": true], topMenuMinimized: true, actionsMenuMinimized: true))
        try store.save([:])
        XCTAssertEqual(try store.loadSettings(), .init(verticalToolbars: ["actions": true], topMenuMinimized: true, actionsMenuMinimized: true))
        try store.saveVertical(false, for: "actions")
        XCTAssertEqual(try store.loadSettings(), .init(verticalToolbars: ["actions": false], topMenuMinimized: true, actionsMenuMinimized: true))
    }

    func testFailedActionsMinimizeWritePreservesTopMenuStyleAndCirclePosition() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("toolbar-positions.json"), store = ControllerToolbarPositionStore(url: url)
        let original = ControllerToolbarSettings(positions: ["actionsMenuButton.portrait": .init(x: 0.2, y: 0.8)],
                                                 verticalToolbars: ["actions": true], topMenuMinimized: true)
        try store.saveSettings(original)
        let before = try Data(contentsOf: url)
        let failing = ControllerToolbarPositionStore(url: url) { _, path in
            try Data("partial actions minimize save".utf8).write(to: path)
            throw NSError(domain: "Forced actions minimize write failure", code: 1)
        }
        XCTAssertThrowsError(try failing.saveActionsMenuMinimized(true))
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(try store.loadSettings(), original)
    }

    func testActionsMinimizedFlagRejectsNonBooleanValuesWithoutChangingBytes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("toolbar-positions.json"), store = ControllerToolbarPositionStore(url: url)
        for raw in ["1", #""true""#, "[]", "{}"] {
            let bytes = Data("{\"version\":1,\"positions\":{},\"actionsMenuMinimized\":\(raw)}".utf8)
            try bytes.write(to: url)
            XCTAssertThrowsError(try store.loadSettings())
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }
}
