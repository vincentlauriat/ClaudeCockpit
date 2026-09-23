import XCTest
import CockpitShared
@testable import SessionsKit

/// Claude Code writes a `cost-state` line for barely one session in ten, so a view that only
/// showed `costStateUSD` would show a dash almost everywhere. The module hands over tokens
/// per model instead, and the view prices them with the rates the user edits in Réglages.
final class ModelTokensTests: XCTestCase {

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

    /// Two models in one session, three turns on one of them.
    private func writeMixedSession() throws {
        var lines = [Line.user(uuid: "mx-u", text: "au travail", at: TestClock.offset(0),
                               sessionId: "sess-mix")]
        for index in 0..<3 {
            lines.append(Line.assistant(
                uuid: "mx-opus-\(index)", at: TestClock.offset(index + 1),
                blocks: [Line.text("réponse \(index)")],
                messageId: "msg-mx-opus-\(index)", model: "claude-opus-5",
                sessionId: "sess-mix",
                inputTokens: 100, outputTokens: 200,
                cacheReadTokens: 300, cacheCreationTokens: 40))
        }
        lines.append(Line.assistant(
            uuid: "mx-haiku", at: TestClock.offset(9), blocks: [Line.text("vite fait")],
            messageId: "msg-mx-haiku", model: "claude-haiku-4-5-20251001",
            sessionId: "sess-mix",
            inputTokens: 7, outputTokens: 11, cacheReadTokens: 13, cacheCreationTokens: 17))
        try fixture.write(lines, to: "\(Line.project)/sess-mix.jsonl")
    }

    func testSessionCarriesItsTokensPerModel() async throws {
        try writeMixedSession()
        try await service.index()

        let session = try XCTUnwrapAsync(try await service.session(id: "sess-mix"))
        XCTAssertEqual(Set(session.tokensByModel.keys),
                       ["claude-opus-5", "claude-haiku-4-5-20251001"])

        let opus = try XCTUnwrap(session.tokensByModel["claude-opus-5"])
        XCTAssertEqual(opus.inputTokens, 300)
        XCTAssertEqual(opus.outputTokens, 600)
        XCTAssertEqual(opus.cacheReadTokens, 900)
        XCTAssertEqual(opus.cacheCreationTokens, 120)
        XCTAssertEqual(opus.total, 1_920)

        let haiku = try XCTUnwrap(session.tokensByModel["claude-haiku-4-5-20251001"])
        XCTAssertEqual(haiku.total, 48)

        // The per-model split must add up to the session totals, or the two disagree on screen.
        XCTAssertEqual(session.tokensByModel.values.map(\.inputTokens).reduce(0, +),
                       session.inputTokens)
        XCTAssertEqual(session.tokensByModel.values.map(\.total).reduce(0, +), session.totalTokens)
    }

    func testTheListCarriesThemToo() async throws {
        try writeMixedSession()
        try await service.index()
        let listed = try await service.listSessions(SessionFilter())
        let session = try XCTUnwrap(listed.first { $0.id == "sess-mix" })
        XCTAssertEqual(session.tokensByModel.count, 2)
    }

    /// Most sessions have no `cost-state` line at all; they still have to be priceable.
    func testASessionWithoutCostStateStillReportsItsTokens() async throws {
        try writeMixedSession()
        try await service.index()
        let session = try XCTUnwrapAsync(try await service.session(id: "sess-mix"))
        XCTAssertNil(session.costStateUSD, "la fixture n'écrit pas de ligne cost-state")
        XCTAssertFalse(session.tokensByModel.isEmpty)
    }

    /// A response written into two transcripts is counted once, here as everywhere else.
    func testDuplicatedResponsesAreNotCountedTwice() async throws {
        let shared = Line.assistant(
            uuid: "dup-1", at: TestClock.offset(0), blocks: [Line.text("partagé")],
            messageId: "msg-dup", model: "claude-opus-5", sessionId: "dup-a",
            inputTokens: 1_000, outputTokens: 2_000)
        try fixture.write([shared], to: "\(Line.project)/dup-a.jsonl")
        try fixture.write(
            [shared.replacingOccurrences(of: "\"dup-a\"", with: "\"dup-b\"")
                .replacingOccurrences(of: "\"dup-1\"", with: "\"dup-2\"")],
            to: "\(Line.project)/dup-b.jsonl")
        try await service.index()

        let first = try XCTUnwrapAsync(try await service.session(id: "dup-a"))
        let second = try XCTUnwrapAsync(try await service.session(id: "dup-b"))
        let inputs = (first.tokensByModel["claude-opus-5"]?.inputTokens ?? 0)
            + (second.tokensByModel["claude-opus-5"]?.inputTokens ?? 0)
        XCTAssertEqual(inputs, 1_000)
    }

    /// Re-reading a transcript must replace the per-model rows, not add to them.
    func testTokensAreNotDoubledByAReread() async throws {
        try writeMixedSession()
        try await service.index()
        let before = try XCTUnwrapAsync(try await service.session(id: "sess-mix"))

        try writeMixedSession()   // atomic rewrite: new inode, read again from byte zero
        try await service.index()
        let after = try XCTUnwrapAsync(try await service.session(id: "sess-mix"))

        XCTAssertEqual(after.tokensByModel, before.tokensByModel)
    }

    func testActivityReportsTokensPerModelOverTheRange() async throws {
        try writeMixedSession()
        try await service.index()

        let report = try await service.activity(
            since: TestClock.offset(-60), until: TestClock.offset(60),
            calendar: TestClock.calendar)

        XCTAssertEqual(report.models.map(\.model).sorted(),
                       ["claude-haiku-4-5-20251001", "claude-opus-5"])
        let opus = try XCTUnwrap(report.models.first { $0.model == "claude-opus-5" })
        XCTAssertEqual(opus.turns, 3)
        XCTAssertEqual(opus.tokens.inputTokens, 300)
        XCTAssertEqual(opus.tokens.outputTokens, 600)
        XCTAssertEqual(report.tokensByModel["claude-opus-5"], opus.tokens)
        XCTAssertEqual(report.tokensByModel.count, 2)

        XCTAssertEqual(report.costUSD, 0, "sans ligne cost-state, le coût connu est nul")
        XCTAssertGreaterThan(report.tokensByModel.values.map(\.total).reduce(0, +), 0,
                             "mais les jetons permettent de l'estimer")
    }
}
