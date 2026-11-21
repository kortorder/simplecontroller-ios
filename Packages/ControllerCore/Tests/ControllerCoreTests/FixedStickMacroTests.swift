import XCTest
@testable import ControllerCore

final class FixedStickMacroTests: XCTestCase {
    func testExactAuditedAliasesAndNativeYAxis() throws {
        let expected: [(String, Double, Double)] = [
            ("U",0,1),("UP",0,1),("R",1,0),("RIGHT",1,0),("D",0,-1),("DOWN",0,-1),
            ("L",-1,0),("LEFT",-1,0),("UR",1,1),("UL",-1,1),("BR",1,-1),("BL",-1,-1)]
        for (alias,x,y) in expected {
            let left = try XCTUnwrap(FixedStickMacro.parse("LS:" + alias + "50"))
            XCTAssertEqual(left.channel, .left)
            XCTAssertEqual(left.position, .init(x:x/2,y:y/2))
            let right = try XCTUnwrap(FixedStickMacro.parse(" rs:" + alias.lowercased() + " \n"))
            XCTAssertEqual(right.channel, .right)
            XCTAssertEqual(right.position, .init(x:x,y:y))
        }
    }
    func testCanonicalRoundTripAndBoundedSourceClamping() throws {
        for direction in FixedStickMacro.Direction.allCases {
            for amount in [0,1,50,100] {
                let value = try FixedStickMacro(channel:.left,direction:direction,percentage:amount)
                XCTAssertEqual(try FixedStickMacro.parse(value.source),value)
            }
        }
        XCTAssertEqual(try FixedStickMacro.parse("LS:U999")?.percentage,100)
        XCTAssertEqual(try FixedStickMacro.parse("RS:UR0")?.position,.zero)
        XCTAssertEqual(try FixedStickMacro.parse("LS:U001")?.source,"LS:UP1")
    }
    func testMalformedOrInventedTokensNeverBecomeVectors() throws {
        for token in ["LS:","RS:0,1","LS:UP-1","LS:UP+1","LS:UP1.5","LS:UP1000","LS:UPNaN",
                      "LS:CENTER","LS:NE","LS:DOWNLEFT","LS:U 50","LS:UR５","LS:UP1X"] {
            XCTAssertThrowsError(try FixedStickMacro.parse(token),token)
        }
        XCTAssertNil(try FixedStickMacro.parse("X360LS"))
        XCTAssertNil(try FixedStickMacro.parse("W"))
        XCTAssertThrowsError(try FixedStickMacro(channel:.right,direction:.down,percentage:-1))
        XCTAssertThrowsError(try FixedStickMacro(channel:.right,direction:.down,percentage:101))
    }
    func testDiagonalAxesRemainIndependentRatherThanRadiallyNormalized() throws {
        let macro = try XCTUnwrap(FixedStickMacro.parse("RS:UR"))
        XCTAssertEqual(macro.position,.init(x:1,y:1))
        XCTAssertEqual(macro.source,"RS:UR100")
    }
}
