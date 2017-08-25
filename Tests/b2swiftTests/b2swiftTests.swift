import XCTest
@testable import b2swift

class b2swiftTests: XCTestCase {
    func testExample() {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct
        // results.
        let backblaze = Backblaze(id: "exampleid", key: "examplekey")
        XCTAssertEqual(backblaze.accountId, "exampleid")
    }


    static var allTests = [
        ("testExample", testExample),
    ]
}
