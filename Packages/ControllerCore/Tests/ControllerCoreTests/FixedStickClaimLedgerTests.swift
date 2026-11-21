import XCTest
@testable import ControllerCore

final class FixedStickClaimLedgerTests: XCTestCase {
    private func macro(_ source: String) throws -> FixedStickMacro { try XCTUnwrap(FixedStickMacro.parse(source)) }
    func testFirstLiveOwnerWinsAndRejectedOwnerDoesNotWakeAfterLift() throws {
        var ledger = FixedStickClaimLedger(); let a = UUID(), b = UUID()
        XCTAssertEqual(ledger.request(owner:a,macro:try macro("LS:UP"),retained:false,occupied:[]),.acquired(replaced:nil))
        XCTAssertEqual(ledger.request(owner:b,macro:try macro("LS:RIGHT"),retained:false,occupied:[]),.rejected)
        ledger.end(owner:a)
        XCTAssertEqual(ledger.request(owner:b,macro:try macro("LS:RIGHT"),retained:false,occupied:[]),.rejected)
        XCTAssertTrue(ledger.claims.isEmpty)
        ledger.end(owner:b)
        XCTAssertEqual(ledger.request(owner:b,macro:try macro("LS:RIGHT"),retained:false,occupied:[]),.acquired(replaced:nil))
    }
    func testManualOccupancyRejectsEntireActivationEvenAcrossTimedOffPhases() throws {
        var ledger = FixedStickClaimLedger(); let owner = UUID()
        XCTAssertEqual(ledger.request(owner:owner,macro:try macro("RS:UL"),retained:false,occupied:[.rightStick]),.rejected)
        ledger.pause(owner:owner)
        XCTAssertEqual(ledger.request(owner:owner,macro:try macro("RS:UL"),retained:false,occupied:[]),.rejected)
        XCTAssertTrue(ledger.claims.isEmpty)
    }
    func testOwnerZeroOrEndNeverReleasesAnotherOwnerOrOtherChannel() throws {
        var ledger = FixedStickClaimLedger(); let a = UUID(), b = UUID()
        ledger.request(owner:a,macro:try macro("LS:UP"),retained:false,occupied:[])
        ledger.request(owner:b,macro:try macro("RS:DOWN"),retained:false,occupied:[])
        ledger.request(owner:b,macro:try macro("LS:UP0"),retained:false,occupied:[])
        XCTAssertEqual(ledger.claims[.left]?.owner,a)
        ledger.end(owner:a)
        XCTAssertNil(ledger.claims[.left]); XCTAssertEqual(ledger.claims[.right]?.owner,b)
    }
    func testRetainedTakeoverBlocksOldActivationPermanently() throws {
        var ledger = FixedStickClaimLedger(); let a = UUID(), b = UUID()
        ledger.request(owner:a,macro:try macro("LS:UP"),retained:true,occupied:[])
        XCTAssertEqual(ledger.request(owner:b,macro:try macro("LS:RIGHT"),retained:false,occupied:[]),.acquired(replaced:a))
        ledger.end(owner:b)
        XCTAssertEqual(ledger.request(owner:a,macro:try macro("LS:UP"),retained:true,occupied:[]),.rejected)
        XCTAssertTrue(ledger.claims.isEmpty)
    }
    func testManualTakeoverOnlyYieldsRetainedClaimsAndNeverRevivesThem() throws {
        var ledger = FixedStickClaimLedger(); let owner = UUID()
        ledger.request(owner:owner,macro:try macro("LS:UP50"),retained:false,occupied:[])
        XCTAssertNil(ledger.yieldRetained(channel:.leftStick))
        XCTAssertEqual(ledger.occupiedChannels,[.leftStick])
        ledger.setRetained(true,owner:owner)
        XCTAssertEqual(ledger.retainedChannels,[.leftStick])
        XCTAssertEqual(ledger.yieldRetained(channel:.leftStick),owner)
        XCTAssertEqual(ledger.request(owner:owner,macro:try macro("LS:UP50"),retained:true,occupied:[]),.rejected)
    }
    func testSameOwnerUpdatesAndGlobalClearHasNoStaleRejection() throws {
        var ledger = FixedStickClaimLedger(); let owner = UUID()
        ledger.request(owner:owner,macro:try macro("LS:UP"),retained:false,occupied:[])
        ledger.request(owner:owner,macro:try macro("LS:BL20"),retained:false,occupied:[])
        XCTAssertEqual(ledger.claims[.left]?.position,.init(x:-0.2,y:-0.2))
        ledger.clear()
        XCTAssertTrue(ledger.claims.isEmpty)
        XCTAssertEqual(ledger.request(owner:owner,macro:try macro("LS:UP"),retained:false,occupied:[]),.acquired(replaced:nil))
    }
}
