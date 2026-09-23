import XCTest
@testable import CockpitShared

final class FRFormatTests: XCTestCase {
    func testTokens() {
        XCTAssertEqual(FRFormat.tokens(999), "999")
        XCTAssertEqual(FRFormat.tokens(12_345), "12,3 k")
        XCTAssertEqual(FRFormat.tokens(250_000), "250 k")
        XCTAssertEqual(FRFormat.tokens(1_260_000), "1,3 M")
        XCTAssertEqual(FRFormat.tokens(2_500_000_000), "2,5 G")
    }

    func testDuration() {
        XCTAssertEqual(FRFormat.duration(30), "30 s")
        XCTAssertEqual(FRFormat.duration(125), "2 min")
        XCTAssertEqual(FRFormat.duration(7_500), "2 h 05")
        XCTAssertEqual(FRFormat.duration(3 * 86_400 + 3_600), "3 j 1 h")
    }

    func testPercent() {
        XCTAssertEqual(FRFormat.percent(0.42), "42 %")
        XCTAssertEqual(FRFormat.percent(42.5, fraction: false, digits: 1), "42,5 %")
    }
}

extension FRFormatTests {
    /// French agrees the singular on 0 and 1, unlike English. The bug this guards against
    /// shipped visibly once: a transcript turn read "1 pièces jointes".
    func testPluralAgreesOnZeroAndOne() {
        XCTAssertEqual(FRFormat.plural(0, "pièce jointe"), "0 pièce jointe")
        XCTAssertEqual(FRFormat.plural(1, "pièce jointe"), "1 pièce jointe")
        XCTAssertEqual(FRFormat.plural(2, "pièce jointe"), "2 pièces jointes")
        XCTAssertEqual(FRFormat.plural(1, "tour"), "1 tour")
        // Built from `integer` rather than written out: the French group separator is a
        // narrow no-break space, and that is `integer`'s business to test, not this one's.
        XCTAssertEqual(FRFormat.plural(1_234, "tour"), "\(FRFormat.integer(1_234)) tours")
    }

    /// Words ending in s, x or z are invariable; an explicit plural covers the rest.
    func testPluralLeavesInvariableWordsAloneAndAcceptsAnExplicitForm() {
        XCTAssertEqual(FRFormat.plural(3, "fois"), "3 fois")
        XCTAssertEqual(FRFormat.plural(3, "prix"), "3 prix")
        XCTAssertEqual(FRFormat.plural(3, "cheval", "chevaux"), "3 chevaux")
        XCTAssertEqual(FRFormat.plural(-2, "tour"), "-2 tours", "the sign must not pick the singular")
    }
}
