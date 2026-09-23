import XCTest
import CockpitShared
@testable import SessionsKit

/// `RecursiveWatcher` reports which files changed. Re-walking the whole archive on every
/// event would spend more time listing it than reading it, so the targeted pass exists —
/// and it must never draw conclusions about the paths it was not told about.
final class TargetedIndexTests: XCTestCase {

    private var fixture: TranscriptFixture!
    private var service: SessionService!

    override func setUpWithError() throws {
        fixture = try TranscriptFixture()
        service = fixture.service()
    }

    override func tearDown() {
        service = nil
        fixture = nil
    }

    private func writeTwoProjects() throws {
        try fixture.write([
            Line.user(uuid: "a-u", text: "premier", at: TestClock.offset(0), sessionId: "sess-a"),
        ], to: "\(Line.project)/sess-a.jsonl")
        try fixture.write([
            Line.user(uuid: "b-u", text: "second", at: TestClock.offset(1), sessionId: "sess-b"),
        ], to: "-Users-test-DevApps-Autre/sess-b.jsonl")
    }

    func testIndexesOnlyTheNamedPaths() async throws {
        try writeTwoProjects()
        let path = fixture.url("\(Line.project)/sess-a.jsonl").path

        let progress = try await service.index(changedPaths: [path])
        XCTAssertEqual(progress.filesTotal, 1, "un seul fichier doit être visité")
        XCTAssertGreaterThan(progress.bytesRead, 0)
        await XCTAssertNotNilAsync(try await service.session(id: "sess-a"))
        await XCTAssertNilAsync(try await service.session(id: "sess-b"),
                                "le fichier non nommé ne doit pas être lu")
    }

    /// The dangerous case: a targeted pass sees a handful of paths. Concluding that everything
    /// else disappeared would repeat, on a partial list, the data loss the empty-walk guard
    /// prevents — and take stars and custom names with it.
    func testATargetedPassNeverPrunesWhatItWasNotToldAbout() async throws {
        try writeTwoProjects()
        try await service.index()
        try await service.setStarred(true, sessionId: "sess-b")
        try await service.rename(sessionId: "sess-b", customName: "Gardé")

        // `sess-b` is genuinely gone from disk, but this pass is not about it.
        try FileManager.default.removeItem(at: fixture.url("-Users-test-DevApps-Autre/sess-b.jsonl"))
        try await service.index(changedPaths: [fixture.url("\(Line.project)/sess-a.jsonl").path])

        let kept = try XCTUnwrapAsync(try await service.session(id: "sess-b"))
        XCTAssertTrue(kept.isStarred)
        XCTAssertEqual(kept.customName, "Gardé")

        // The full pass is what notices, and it still does.
        try await service.index()
        await XCTAssertNilAsync(try await service.session(id: "sess-b"))
    }

    /// The watcher sends an empty list when the kernel told it events were dropped: the
    /// changed set is unknown, not empty, so the only safe reading is "rescan everything".
    func testAnEmptyListMeansRescanEverything() async throws {
        try writeTwoProjects()
        let progress = try await service.index(changedPaths: [])
        XCTAssertEqual(progress.filesTotal, 2)
        await XCTAssertNotNilAsync(try await service.session(id: "sess-a"))
        await XCTAssertNotNilAsync(try await service.session(id: "sess-b"))
    }

    func testAppendedLinesArePickedUpByATargetedPass() async throws {
        try writeTwoProjects()
        try await service.index()
        let relative = "\(Line.project)/sess-a.jsonl"

        try fixture.append(Line.assistant(
            uuid: "a-a", at: TestClock.offset(5), blocks: [Line.text("ajout")],
            messageId: "msg-a-a", sessionId: "sess-a"), to: relative)
        try await service.index(changedPaths: [fixture.url(relative).path])

        let session = try XCTUnwrapAsync(try await service.session(id: "sess-a"))
        XCTAssertEqual(session.assistantTurns, 1)
    }

    /// Anything that is not a transcript inside the archive is dropped rather than acted on:
    /// the watcher reports directories and sibling files too.
    func testIgnoresPathsThatAreNotTranscriptsOfThisArchive() async throws {
        try writeTwoProjects()
        let outside = fixture.home.appendingPathComponent("ailleurs.jsonl")
        try "{}".write(to: outside, atomically: true, encoding: .utf8)

        let progress = try await service.index(changedPaths: [
            outside.path,
            fixture.paths.projectsDir.path,
            fixture.url(Line.project).path,
            "/n/existe/pas.jsonl",
        ])
        XCTAssertEqual(progress.filesTotal, 0, "aucun de ces chemins n'est un transcript à lire")
        await XCTAssertNilAsync(try await service.session(id: "sess-a"))
    }

    func testDuplicatePathsAreVisitedOnce() async throws {
        try writeTwoProjects()
        let path = fixture.url("\(Line.project)/sess-a.jsonl").path
        let progress = try await service.index(changedPaths: [path, path, path])
        XCTAssertEqual(progress.filesTotal, 1)
    }
}

/// An exported document is built from a transcript, and a transcript is not a trusted source.
final class ExportSafetyTests: XCTestCase {

    private func session(with link: PRLink) -> SessionRef {
        SessionRef(
            id: "s", projectDir: "p", cwd: "/tmp/demo", title: "Export",
            firstTimestamp: TestClock.start, lastTimestamp: TestClock.offset(5),
            prLinks: [link])
    }

    /// `URL(string:)` parses `javascript:` happily, and escaping the markup does nothing about
    /// the scheme — the exported file would carry a live hostile link.
    func testAHostileSchemeIsShownAsTextNotAsALink() throws {
        let hostile = try XCTUnwrap(URL(string: "javascript:alert(1)"))
        let session = session(with: PRLink(
            number: 7, url: hostile, repository: "test/demo", timestamp: TestClock.start))

        let html = SessionExporter.html(session: session, messages: [])
        XCTAssertFalse(html.contains("<a href=\"javascript"), html)
        XCTAssertFalse(html.contains("href=\"javascript:alert(1)\""))
        XCTAssertTrue(html.contains("#7"), "le numéro reste lisible")

        let markdown = SessionExporter.markdown(session: session, messages: [])
        XCTAssertFalse(markdown.contains("](javascript:"), markdown)
        XCTAssertTrue(markdown.contains("#7"))
    }

    func testHttpAndHttpsStayClickable() {
        for address in ["https://github.com/test/demo/pull/7", "http://example.com/pull/7"] {
            let session = session(with: PRLink(
                number: 7, url: URL(string: address)!, repository: "test/demo",
                timestamp: TestClock.start))
            XCTAssertTrue(SessionExporter.html(session: session, messages: [])
                .contains("<a href=\"\(address)\">"), address)
            XCTAssertTrue(SessionExporter.markdown(session: session, messages: [])
                .contains("[#7](\(address))"), address)
        }
    }

    func testAttachmentCountsAgreeInFrench() {
        XCTAssertEqual(SessionExporter.attachmentNote(1), "1 pièce jointe masquée.")
        XCTAssertEqual(SessionExporter.attachmentNote(3), "3 pièces jointes masquées.")
    }
}
