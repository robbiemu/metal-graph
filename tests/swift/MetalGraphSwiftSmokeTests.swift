import MetalGraph
import XCTest

final class MetalGraphSwiftSmokeTests: XCTestCase {
    func testVersionMatchesHeaderMacros() {
        let version = mgVersion()
        XCTAssertEqual(version.major, UInt32(MG_VERSION_MAJOR))
        XCTAssertEqual(version.minor, UInt32(MG_VERSION_MINOR))
        XCTAssertEqual(version.patch, UInt32(MG_VERSION_PATCH))
    }
}
