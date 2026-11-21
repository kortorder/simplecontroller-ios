import XCTest
@testable import ControllerCore

final class FloatingEditingTests: XCTestCase {
    private func fixture() throws -> (ControllerProfile, FloatingCanvasSnapshot) {
        let a = ProfileControl(name:"A",actions:[.a]), b = ProfileControl(name:"B",payload:"X360B,W")
        let positions = [ProfilePlacement(id:a.id,position:.init(x:0.2,y:0.3)),.init(id:b.id,position:.init(x:0.6,y:0.3))]
        let profile = try ControllerProfile(controls:[a,b],portrait:positions,landscape:positions)
        return (profile,.init(width:400,height:800,frames:[a.id:.init(x:50,y:210,width:60,height:60),b.id:.init(x:210,y:210,width:60,height:60)]))
    }
    func testConversionUsesMeasuredGeometryAndUnfloatRestoresExactCanonicalData() throws {
        var (p,snapshot) = try fixture(); let original = p, page = p.pages[0].id
        let zoneID = try p.convertToFloatingButtons(on:page,memberIDs:p.controls.map(\.id),kind:.buttonGroup,name:"Group",snapshots:[.portrait:snapshot])
        let zone = p.pages[0].floatingButtonZones[0]
        XCTAssertEqual(zone.portraitGeometry?.canvasWidth,400); XCTAssertEqual(zone.portraitGeometry?.canvasHeight,800)
        XCTAssertEqual(zone.portraitMembers.map(\.frame),p.controls.map { snapshot.frames[$0.id]! })
        XCTAssertEqual(p.controls,original.controls); XCTAssertEqual(p.portrait,original.portrait); XCTAssertEqual(p.landscape,original.landscape)
        XCTAssertNil(zone.landscapeGeometry); XCTAssertNil(zone.startMemberID)
        try p.unfloatButtons(zoneID,on:page); XCTAssertEqual(p,original)
    }
    func testSingleButtonStartsOnItsMemberAndDuplicateConversionIsAtomic() throws {
        var (p,snapshot) = try fixture(); let id = p.controls[0].id, page = p.pages[0].id
        _ = try p.convertToFloatingButtons(on:page,memberIDs:[id],kind:.singleButton,name:"A",snapshots:[.portrait:snapshot])
        XCTAssertEqual(p.pages[0].floatingButtonZones[0].startMemberID,id)
        let before = p
        XCTAssertThrowsError(try p.convertToFloatingButtons(on:page,memberIDs:[id],kind:.singleButton,name:"Again",snapshots:[.portrait:snapshot]))
        XCTAssertEqual(p,before)
    }
    func testMissingMeasurementOrImpossibleFitDoesNotMutateProfile() throws {
        var (p,snapshot) = try fixture(); let before = p
        snapshot.frames.removeValue(forKey:p.controls[1].id)
        XCTAssertThrowsError(try p.convertToFloatingButtons(on:p.pages[0].id,memberIDs:p.controls.map(\.id),kind:.buttonGroup,name:"Group",snapshots:[.portrait:snapshot]))
        XCTAssertEqual(p,before)
        let one = FloatingCanvasSnapshot(width:400,height:100,frames:[p.controls[0].id:.init(x:0,y:0,width:60,height:60)])
        XCTAssertThrowsError(try p.convertToFloatingButtons(on:p.pages[0].id,memberIDs:[p.controls[0].id],kind:.singleButton,name:"Small",snapshots:[.portrait:one]))
        XCTAssertEqual(p,before)
    }
    func testPreparingOrientationScalesOnlyActivationAndCapturesActualRestoration() throws {
        var (p,snapshot) = try fixture(); let page = p.pages[0].id
        let zoneID = try p.convertToFloatingButtons(on:page,memberIDs:p.controls.map(\.id),kind:.buttonGroup,name:"Group",snapshots:[.portrait:snapshot])
        let original = p.pages[0].floatingButtonZones[0]
        let landscape = FloatingCanvasSnapshot(width:800,height:400,frames:[p.controls[0].id:.init(x:100,y:80,width:60,height:60),p.controls[1].id:.init(x:420,y:80,width:60,height:60)])
        try p.prepareFloatingButtonOrientation(zoneID,on:page,orientation:.landscape,snapshot:landscape)
        let zone = p.pages[0].floatingButtonZones[0]
        XCTAssertEqual(zone.landscapeGeometry?.zone,.init(x:100,y:105,width:440,height:30))
        XCTAssertEqual(zone.landscapeMembers,original.portraitMembers)
        XCTAssertEqual(zone.landscapeRestoration.map(\.frame),p.controls.map { landscape.frames[$0.id]! })
        XCTAssertEqual(zone.portraitGeometry,original.portraitGeometry)
    }
    func testDetachedMemberMoveDoesNotChangeCanonicalOrRestoration() throws {
        var (p,snapshot) = try fixture(); let page = p.pages[0].id, member = p.controls[1].id
        let zoneID = try p.convertToFloatingButtons(on:page,memberIDs:p.controls.map(\.id),kind:.buttonGroup,name:"Group",snapshots:[.portrait:snapshot])
        let original = p
        try p.setFloatingMemberFrame(member,zoneID:zoneID,on:page,orientation:.portrait,frame:.init(x:150,y:250,width:60,height:60),snapshot:snapshot)
        XCTAssertEqual(p.portrait,original.portrait); XCTAssertEqual(p.controls,original.controls)
        XCTAssertEqual(p.pages[0].floatingButtonZones[0].portraitRestoration,original.pages[0].floatingButtonZones[0].portraitRestoration)
        XCTAssertNotEqual(p.pages[0].floatingButtonZones[0].portraitMembers,original.pages[0].floatingButtonZones[0].portraitMembers)
        let before = p
        XCTAssertThrowsError(try p.setFloatingMemberFrame(member,zoneID:zoneID,on:page,orientation:.portrait,frame:.init(x:900,y:250,width:60,height:60),snapshot:snapshot))
        XCTAssertEqual(p,before)
    }
    func testActivationZoneMovesWithinActualCanvasWithoutMovingMembers() throws {
        var (p,snapshot) = try fixture(); let page = p.pages[0].id
        let id = try p.convertToFloatingButtons(on:page,memberIDs:[p.controls[0].id],kind:.singleButton,name:"Button",snapshots:[.portrait:snapshot])
        let members = p.pages[0].floatingButtonZones[0].portraitMembers
        try p.setFloatingZoneGeometry(id,on:page,orientation:.portrait,rectangle:.init(x:0,y:400,width:100,height:120),canvasWidth:400,canvasHeight:800)
        XCTAssertEqual(p.pages[0].floatingButtonZones[0].portraitGeometry?.zone.y,400)
        XCTAssertEqual(p.pages[0].floatingButtonZones[0].portraitMembers,members)
        let before = p
        XCTAssertThrowsError(try p.setFloatingZoneGeometry(id,on:page,orientation:.portrait,rectangle:.init(x:390,y:400,width:100,height:120),canvasWidth:400,canvasHeight:800))
        XCTAssertEqual(p,before)
    }
}
