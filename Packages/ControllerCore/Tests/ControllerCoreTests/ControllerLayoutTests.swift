import Foundation
import XCTest
@testable import ControllerCore

final class ControllerLayoutTests: XCTestCase {
    func testDefaultsContainTwentyIndependentControlsInEachOrientation() {
        XCTAssertEqual(ControllerControlID.allCases.count, 20)
        for orientation in ControllerOrientation.allCases {
            let placements = ControllerLayout.default.placements(for: orientation)
            XCTAssertEqual(placements.count, 20)
            XCTAssertEqual(Set(placements.map(\.id)), Set(ControllerControlID.allCases))
        }
        XCTAssertTrue(ControllerLayout.default.isValid)
    }

    func testDefaultsFitReferenceCanvasWithMinimumTouchTargetsAndNoOverlap() {
        for (orientation, width, height): (ControllerOrientation, Double, Double) in [
            (.portrait, 337, 428), (.landscape, 494, 208)
        ] {
            let placements = ControllerLayout.default.placements(for: orientation)
            for (index, item) in placements.enumerated() {
                let radius = item.id.defaultDiameter / 2
                let x = item.position.x * width
                let y = item.position.y * height
                XCTAssertGreaterThanOrEqual(item.id.defaultDiameter, item.id.isStick ? 104 : 44)
                XCTAssertGreaterThanOrEqual(x + 0.001, radius)
                XCTAssertGreaterThanOrEqual(y + 0.001, radius)
                XCTAssertLessThanOrEqual(x + radius, width + 0.001)
                XCTAssertLessThanOrEqual(y + radius, height + 0.001)
                for other in placements.dropFirst(index + 1) {
                    let dx = x - other.position.x * width
                    let dy = y - other.position.y * height
                    XCTAssertGreaterThanOrEqual(hypot(dx, dy) + 0.001,
                        radius + other.id.defaultDiameter / 2,
                        "\(orientation): \(item.id) overlaps \(other.id)")
                }
            }
        }
    }

    func testEditedLayoutSaveRoundTripPreservesBothOrientationsAndOrder() throws {
        var layout = ControllerLayout.default
        try layout.move(.a, to: .init(x: 0.25, y: 0.3), orientation: .portrait)
        try layout.move(.rightStick, to: .init(x: 0.71, y: 0.43), orientation: .landscape)
        let data = try ControllerLayoutCodec.encode(layout)
        XCTAssertEqual(try ControllerLayoutCodec.decode(data), layout)
        XCTAssertEqual(try ControllerLayoutCodec.encode(layout), data)
    }

    func testMoveChangesOnlyChosenControlAndOrientation() throws {
        let original = ControllerLayout.default
        var layout = original
        try layout.move(.leftStick, to: .init(x: 0.1, y: 0.2), orientation: .portrait)
        XCTAssertEqual(layout.landscape, original.landscape)
        for id in ControllerControlID.allCases where id != .leftStick {
            XCTAssertEqual(layout.placement(for: id, orientation: .portrait),
                           original.placement(for: id, orientation: .portrait))
        }
        XCTAssertEqual(layout.placement(for: .leftStick, orientation: .portrait).position,
                       .init(x: 0.1, y: 0.2))
    }

    func testMoveClampsFiniteCoordinatesAndPromotesMovedControl() throws {
        var layout = ControllerLayout.default
        try layout.move(.guide, to: .init(x: -50, y: 50), orientation: .landscape)
        XCTAssertEqual(layout.landscape.last?.id, .guide)
        XCTAssertEqual(layout.landscape.last?.position, .init(x: 0, y: 1))
        XCTAssertEqual(layout.landscape.count, 20)
        XCTAssertTrue(layout.isValid)
    }

    func testNonfiniteMovesThrowWithoutChangingLayout() {
        var layout = ControllerLayout.default
        for position in [NormalizedControlPosition(x: .nan, y: 0), .init(x: 0, y: .infinity),
                         .init(x: -.infinity, y: 0)] {
            XCTAssertThrowsError(try layout.move(.a, to: position, orientation: .portrait))
            XCTAssertEqual(layout, .default)
        }
    }

    func testInvalidSavedCoordinatesAreRejectedRatherThanClamped() throws {
        for x: Any in [-0.01, 1.01, true, "0.5", NSNull()] {
            var object = try layoutObject()
            var placements = try XCTUnwrap(object["portrait"] as? [[String: Any]])
            placements[0]["position"] = ["x": x, "y": 0.5]
            object["portrait"] = placements
            XCTAssertThrowsError(try ControllerLayoutCodec.decode(data(object)))
        }
    }

    func testDuplicateControlIsRejectedEvenWhenCountIsTwenty() throws {
        var placements = ControllerLayout.default.portrait
        placements[1] = placements[0]
        XCTAssertThrowsError(try ControllerLayout(portrait: placements, landscape: ControllerLayout.default.landscape)) {
            XCTAssertEqual($0 as? ControllerLayoutError, .duplicateControls)
        }
        var object = try layoutObject()
        var values = try XCTUnwrap(object["landscape"] as? [[String: Any]])
        values[1] = values[0]
        object["landscape"] = values
        XCTAssertThrowsError(try ControllerLayoutCodec.decode(data(object)))
    }

    func testMissingControlAndMissingOrientationAreRejected() throws {
        XCTAssertThrowsError(try ControllerLayout(portrait: Array(ControllerLayout.default.portrait.dropLast()),
                                                  landscape: ControllerLayout.default.landscape)) {
            XCTAssertEqual($0 as? ControllerLayoutError, .missingControls)
        }
        var object = try layoutObject()
        object.removeValue(forKey: "portrait")
        XCTAssertThrowsError(try ControllerLayoutCodec.decode(data(object)))
    }

    func testUnknownControlIsRejectedRatherThanLostOnSave() throws {
        var object = try layoutObject()
        var placements = try XCTUnwrap(object["portrait"] as? [[String: Any]])
        placements[0]["id"] = "futureControl"
        object["portrait"] = placements
        XCTAssertThrowsError(try ControllerLayoutCodec.decode(data(object)))
    }

    func testUnknownFieldsAtEveryLevelAreRejectedRatherThanLost() throws {
        var object = try layoutObject()
        object["futureSetting"] = true
        XCTAssertThrowsError(try ControllerLayoutCodec.decode(data(object)))
        object = try layoutObject()
        var placements = try XCTUnwrap(object["portrait"] as? [[String: Any]])
        placements[0]["futureSetting"] = true
        object["portrait"] = placements
        XCTAssertThrowsError(try ControllerLayoutCodec.decode(data(object)))
        placements[0].removeValue(forKey: "futureSetting")
        placements[0]["position"] = ["x": 0.5, "y": 0.5, "rotation": 1]
        object["portrait"] = placements
        XCTAssertThrowsError(try ControllerLayoutCodec.decode(data(object)))
    }

    func testFutureVersionReturnsDefaultsAndPreservesExactOriginalData() throws {
        let saved = Data("{\"version\":99,\"futureField\":\"preserve me\"}".utf8)
        XCTAssertThrowsError(try ControllerLayoutCodec.decode(saved)) {
            XCTAssertEqual($0 as? ControllerLayoutError, .unsupportedVersion(99))
        }
        let result = ControllerLayoutCodec.restore(from: saved)
        XCTAssertEqual(result.layout, .default)
        XCTAssertEqual(result.recoveredData, saved)
        XCTAssertEqual(result.issue, .unsupportedVersion(99))
    }

    func testCorruptOrOversizedDataReturnsUsableDefaultsWithoutDestroyingOriginal() {
        for saved in [Data("{".utf8), Data("[]".utf8),
                      Data(repeating: 32, count: ControllerLayoutCodec.maximumBytes + 1)] {
            let result = ControllerLayoutCodec.restore(from: saved)
            XCTAssertEqual(result.layout, .default)
            XCTAssertEqual(result.recoveredData, saved)
            XCTAssertNotNil(result.issue)
        }
    }

    func testAbsentOrValidStorageDoesNotCreateRecoveryWarning() throws {
        let empty = ControllerLayoutCodec.restore(from: nil)
        XCTAssertEqual(empty.layout, .default)
        XCTAssertNil(empty.issue)
        XCTAssertNil(empty.recoveredData)
        var layout = ControllerLayout.default
        try layout.move(.share, to: .init(x: 0.1, y: 0.9), orientation: .portrait)
        let restored = ControllerLayoutCodec.restore(from: try ControllerLayoutCodec.encode(layout))
        XCTAssertEqual(restored.layout, layout)
        XCTAssertNil(restored.issue)
        XCTAssertNil(restored.recoveredData)
    }

    func testStickSurfacesAndClickButtonsMapIndependently() {
        XCTAssertNil(ControllerControlID.leftStick.padButton)
        XCTAssertNil(ControllerControlID.rightStick.padButton)
        XCTAssertEqual(ControllerControlID.leftStickClick.padButton, .leftStick)
        XCTAssertEqual(ControllerControlID.rightStickClick.padButton, .rightStick)
        XCTAssertEqual(Set(ControllerControlID.allCases.compactMap(\.padButton)), Set(PadButton.allCases))
        XCTAssertEqual(ControllerControlID.leftTrigger.padButton, .leftTrigger)
        XCTAssertEqual(ControllerControlID.rightTrigger.padButton, .rightTrigger)
        XCTAssertEqual(ControllerControlID.guide.padButton, .guide)
        XCTAssertEqual(ControllerControlID.share.padButton, .share)
    }

    private func layoutObject() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: ControllerLayoutCodec.encode(.default)) as? [String: Any])
    }
    private func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
    }
}
