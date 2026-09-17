import XCTest
@testable import Clip

/// The bare-hex acceptance rules are the whole point of HexColor: too loose
/// and a git SHA becomes a swatch, too strict and half the copied colors in
/// the world stay plain text. Every rule in the doc comment gets one test.
final class HexColorTests: XCTestCase {

    func test_hashedSixDigit_isRecognised() {
        XCTAssertEqual(HexColor.normalised("#3CFFD0"), "#3CFFD0")
    }

    func test_hashedThreeDigit_isRecognised() {
        XCTAssertEqual(HexColor.normalised("#fff"), "#FFF")
    }

    func test_hashedEightDigit_withAlpha_isRecognised() {
        XCTAssertEqual(HexColor.normalised("#3CFFD0FF"), "#3CFFD0FF")
    }

    func test_output_isAlwaysUppercasedWithHash() {
        XCTAssertEqual(HexColor.normalised("abcdef"), "#ABCDEF")
    }

    func test_bareHexWithALetter_isAcceptedAsAColor() {
        // "abcdef" and "facade" are real hex-with-letters strings people copy.
        XCTAssertEqual(HexColor.normalised("abcdef"), "#ABCDEF")
        XCTAssertEqual(HexColor.normalised("facade"), "#FACADE")
    }

    func test_bareAllDigitString_isRejected_becauseItIsANumberNotAColor() {
        // The one rule that exists specifically so a phone number or a plain
        // six-digit number never becomes a swatch.
        XCTAssertNil(HexColor.normalised("123456"))
    }

    func test_gitShortSHA_thatIsAllDigits_isRejected() {
        XCTAssertNil(HexColor.normalised("104857"))
    }

    func test_wrongLength_isRejected() {
        XCTAssertNil(HexColor.normalised("#ABCD"))      // 4 digits: not 3/6/8
        XCTAssertNil(HexColor.normalised("ABCDE"))       // 5 digits
        XCTAssertNil(HexColor.normalised("#ABCDEF0"))    // 7 digits
    }

    func test_nonHexCharacters_areRejected() {
        XCTAssertNil(HexColor.normalised("zzzzzz"))
        XCTAssertNil(HexColor.normalised("#GGGGGG"))
    }

    func test_emptyOrWhitespace_isRejected() {
        XCTAssertNil(HexColor.normalised(""))
        XCTAssertNil(HexColor.normalised("   "))
    }

    func test_wholeClippingMustBeTheToken_proseContainingAHexIsNotAColor() {
        // The doc comment is explicit: a hex found INSIDE prose never matches;
        // only a clipping that IS that one token does.
        XCTAssertNil(HexColor.normalised("the brand color is #3CFFD0 today"))
    }

    func test_surroundingWhitespace_isTrimmedBeforeMatching() {
        XCTAssertEqual(HexColor.normalised("  #3CFFD0  \n"), "#3CFFD0")
    }

    func test_matches_mirrorsNormalised() {
        XCTAssertTrue(HexColor.matches("#3CFFD0"))
        XCTAssertFalse(HexColor.matches("123456"))
    }
}
