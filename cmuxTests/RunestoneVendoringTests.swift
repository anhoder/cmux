import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class RunestoneVendoringTests: XCTestCase {
    func testVendoredRunestoneSmokeSnapshot() {
        let snapshot = VendoredRunestoneSupport.makeSmokeSnapshot()

        XCTAssertEqual(snapshot.text, "# cmux\nVendored Runestone\n")
        XCTAssertTrue(snapshot.isEditable)
        XCTAssertTrue(snapshot.isSelectable)
        XCTAssertEqual(snapshot.themeTypeName, "DefaultTheme")
    }
}
