import XCTest
@testable import CockpitShared

final class FrontmatterTests: XCTestCase {
    func testParsesFieldsAndBody() {
        let text = """
        ---
        name: my-skill
        description: "Does things"
        ---
        # Title
        body
        """
        let fm = Frontmatter.parse(text)
        XCTAssertEqual(fm.name, "my-skill")
        XCTAssertEqual(fm.description, "Does things")
        XCTAssertEqual(fm.body, "# Title\nbody")
    }

    func testFoldedDescription() {
        let text = "---\ndescription: >\n  first line\n  second line\n---\nbody"
        let fm = Frontmatter.parse(text)
        XCTAssertEqual(fm.description, "first line second line")
        XCTAssertEqual(fm.body, "body")
    }

    func testNoFrontmatter() {
        let fm = Frontmatter.parse("# Just markdown")
        XCTAssertTrue(fm.fields.isEmpty)
        XCTAssertEqual(fm.body, "# Just markdown")
    }
}
