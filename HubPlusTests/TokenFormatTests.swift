import XCTest
@testable import HubPlus

final class TokenFormatTests: XCTestCase {
    func testVerbatimBelowOneThousand() {
        XCTAssertEqual(TokenFormat.compact(0), "0")
        XCTAssertEqual(TokenFormat.compact(999), "999")
    }

    func testThousandsGetOneDecimalOnlyBelowTenK() {
        XCTAssertEqual(TokenFormat.compact(1_000), "1k")       // ".0" is trimmed
        XCTAssertEqual(TokenFormat.compact(9_400), "9.4k")
        XCTAssertEqual(TokenFormat.compact(9_960), "10k")      // rounds past 9.95 → integer form
        XCTAssertEqual(TokenFormat.compact(604_000), "604k")
    }

    func testRoundingPromotesToTheNextUnit() {
        // 999_950 / 1e3 = 999.95 → would print "1000k"; must promote to "1M".
        XCTAssertEqual(TokenFormat.compact(999_950), "1M")
    }

    func testMillionsAndBillions() {
        XCTAssertEqual(TokenFormat.compact(1_230_000), "1.2M")
        XCTAssertEqual(TokenFormat.compact(604_137_000), "604M")
        XCTAssertEqual(TokenFormat.compact(1_200_000_000), "1.2B")
    }
}
