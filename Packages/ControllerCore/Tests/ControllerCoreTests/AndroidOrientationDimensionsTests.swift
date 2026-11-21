import XCTest
@testable import ControllerCore

final class AndroidOrientationDimensionsTests: XCTestCase {
    private func fixture(type: String = "BUTTON", payload: String = "X360A", landscape: Bool = true) throws -> (AndroidProfileDocument, ControllerProfile) {
        let l = landscape ? #", "landscapeGeometry":{"canvasWidth":800,"canvasHeight":400,"controls":{"c":{"x":200,"y":100,"w":200,"h":80,"unknownL":9007199254740993}}}"# : ""
        let data = Data(#"{"formatVersion":10,"homePageId":"p","pages":[{"id":"p","name":"Main","controls":[{"id":"c","name":"Sized","type":"\#(type)","payload":"\#(payload)","x":20,"y":30,"w":100,"h":140}],"portraitGeometry":{"canvasWidth":400,"canvasHeight":800,"controls":{"c":{"x":20,"y":30,"w":100,"h":140,"unknownP":9223372036854775809}}}\#(l)}]}"#.utf8)
        let d = try AndroidProfileDocument.parse(data)
        let plan = try AndroidProfileImportPlan.prepare(d, archiveID: UUID(), portrait: .init(width: 400, height: 800), landscape: .init(width: 800, height: 400))
        return (d, try XCTUnwrap(plan.profiles.first?.profile))
    }
    private func preview(_ p: ControllerProfile, _ d: AndroidProfileDocument) -> AndroidEditedExportPreview {
        .prepare(profile: p, original: d, source: p.androidSources[0])
    }
    private func exported(_ p: ControllerProfile, _ d: AndroidProfileDocument) throws -> AndroidProfileDocument {
        let result = preview(p, d)
        return try .parse(XCTUnwrap(result.data, result.diagnostics.map(\.message).joined(separator: " | ")))
    }
    func testButtonAndTouchpadImportPreserveDistinctOrientationDimensionsAndExactOriginal() throws {
        for (type, payload) in [("BUTTON", "X360A"), ("TOUCHPAD", "")] {
            let (d, p) = try fixture(type: type, payload: payload), c = try XCTUnwrap(p.controls.first)
            XCTAssertEqual(c.dimensions(for: .portrait), .init(width: 100, height: 140))
            XCTAssertEqual(c.dimensions(for: .landscape), .init(width: 200, height: 80))
            XCTAssertEqual(c.resolvedWidth, 100); XCTAssertEqual(c.resolvedHeight, 140)
            XCTAssertTrue(preview(p, d).isUnchanged); XCTAssertEqual(preview(p, d).data, d.originalData)
            XCTAssertEqual(p.androidSources[0].exportBaseline?.controls[0].landscape.importedWidth, 200)
        }
    }
    func testLandscapeOnlyResizeKeepsPortraitAndUnknownNumbers() throws {
        let (d, original) = try fixture(); var p = original
        p.controls[0].orientationDimensions.landscape = .init(width: 240, height: 100)
        let next = try exported(p, d), page = next.profiles[0].pages[0].value
        XCTAssertEqual(page["portraitGeometry"], d.profiles[0].pages[0].value["portraitGeometry"])
        let g = page["landscapeGeometry"]?["controls"]?["c"]
        XCTAssertEqual(g?["w"]?.numberValue?.rawValue, "240"); XCTAssertEqual(g?["h"]?.numberValue?.rawValue, "100")
        XCTAssertEqual(g?["x"]?.numberValue?.rawValue, "180"); XCTAssertEqual(g?["y"]?.numberValue?.rawValue, "90")
        XCTAssertEqual(g?["unknownL"], d.profiles[0].pages[0].value["landscapeGeometry"]?["controls"]?["c"]?["unknownL"])
        let imported = try AndroidProfileImportPlan.prepare(next, archiveID: UUID(), portrait: .init(width: 400, height: 800), landscape: .init(width: 800, height: 400))
        XCTAssertEqual(imported.profiles[0].profile.controls[0].orientationDimensions, p.controls[0].orientationDimensions)
    }
    func testPortraitResizePreservesMissingLandscapeFallbackExplicitly() throws {
        let (d, original) = try fixture(landscape: false); var p = original
        XCTAssertEqual(p.controls[0].dimensions(for: .landscape), .init(width: 50, height: 70))
        p.controls[0].orientationDimensions.portrait = .init(width: 120, height: 160)
        let page = try exported(p, d).profiles[0].pages[0].value
        XCTAssertEqual(page["portraitGeometry"]?["controls"]?["c"]?["w"]?.numberValue?.rawValue, "120")
        XCTAssertEqual(page["landscapeGeometry"]?["controls"]?["c"]?["w"]?.numberValue?.rawValue, "100")
        XCTAssertEqual(page["landscapeGeometry"]?["controls"]?["c"]?["h"]?.numberValue?.rawValue, "140")
    }
    func testPriorImportBaselineDoesNotRepairSavedSharedSizeOrRewriteArchivedLandscape() throws {
        let (d, imported) = try fixture(); var p = imported
        p.controls[0].orientationDimensions = .init()
        let old = try AndroidSourceExportBaseline.capture(profile: p, source: p.androidSources[0], original: d,
            portrait: .init(width: 400, height: 800), landscape: .init(width: 800, height: 400))
        p.androidSources[0] = p.androidSources[0].withExportBaseline(old)
        XCTAssertEqual(p.controls[0].dimensions(for: .landscape), .init(width: 100, height: 140))
        XCTAssertTrue(preview(p, d).isUnchanged)
        p.controls[0].name = "Renamed"
        let page = try exported(p, d).profiles[0].pages[0].value
        XCTAssertEqual(page["landscapeGeometry"], d.profiles[0].pages[0].value["landscapeGeometry"])
        p.controls[0].orientationDimensions.landscape = .init(width: 160, height: 120)
        let resized = try exported(p, d).profiles[0].pages[0].value
        XCTAssertEqual(resized["landscapeGeometry"]?["controls"]?["c"]?["w"]?.numberValue?.rawValue, "160")
        XCTAssertEqual(resized["portraitGeometry"], d.profiles[0].pages[0].value["portraitGeometry"])
    }
    func testCopiedControlKeepsBothSourceDimensions() throws {
        let (d, imported) = try fixture(); var p = imported
        let original = p.controls[0]; var copied = original; copied.id = UUID()
        try p.addControl(copied, toPage: p.homePageID); try p.duplicateSourceBinding(from: original.id, to: copied.id)
        let copyID = try XCTUnwrap(p.androidSources[0].controls.first { $0.nativeID == copied.id }?.exportID)
        let page = try exported(p, d).profiles[0].pages[0].value
        for orientation in ["portraitGeometry", "landscapeGeometry"] {
            for key in ["w", "h", "unknownP", "unknownL"] {
                XCTAssertEqual(page[orientation]?["controls"]?[copyID]?[key], page[orientation]?["controls"]?["c"]?[key])
            }
        }
    }
    func testLegacyArrayRejectsIndependentSizeEditInsteadOfDroppingIt() throws {
        let d = try AndroidProfileDocument.parse(Data(#"[{"id":"c","type":"BUTTON","name":"A","payload":"X360A","x":0,"y":0,"w":100,"h":100}]"#.utf8))
        var p = try AndroidProfileImportPlan.prepare(d, archiveID: UUID()).profiles[0].profile
        XCTAssertTrue(preview(p, d).isUnchanged)
        p.controls[0].orientationDimensions.landscape?.width += 10
        let result = preview(p, d)
        XCTAssertFalse(result.canExport); XCTAssertTrue(result.diagnostics.contains { $0.message.contains("separate orientation") })
    }
}
