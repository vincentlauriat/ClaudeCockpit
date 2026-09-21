import XCTest
@testable import UsageKit

final class TranscriptScannerTests: XCTestCase {
    private var fixture: TranscriptFixture!

    private let sessionA = "sess-a"
    private let sessionB = "sess-b"
    private let cwdA = "/Users/test/DevApps/ProjA"
    private let cwdB = "/Users/test/DevApps/ProjB"
    private let fileA = "-Users-test-DevApps-ProjA/sess-a.jsonl"
    private let fileB = "-Users-test-DevApps-ProjB/sess-b.jsonl"
    private let fileSub = "-Users-test-DevApps-ProjA/subagents/agent-explore.jsonl"

    private let t0 = TestClock.date("2026-09-23T09:00:00Z")

    override func setUpWithError() throws {
        fixture = try TranscriptFixture()
        try seed()
    }

    override func tearDown() {
        fixture = nil
    }

    /// Two session transcripts plus one sub-agent transcript. The sub-agent file repeats
    /// `msg-a2`, which is exactly the duplication `message.id` dedupe exists for.
    private func seed() throws {
        try fixture.write([
            TranscriptFixture.aiTitleLine(sessionId: sessionA, title: "Portage d'UsageKit", cwd: cwdA),
            TranscriptFixture.userLine(sessionId: sessionA, cwd: cwdA, timestamp: t0),
            TranscriptFixture.assistantLine(
                uuid: "uuid-a1", messageId: "msg-a1", sessionId: sessionA,
                model: "claude-opus-5", timestamp: t0, cwd: cwdA,
                inputTokens: 1_000, outputTokens: 500,
                cacheReadTokens: 2_000, cacheCreationTokens: 100),
            TranscriptFixture.assistantLine(
                uuid: "uuid-a2", messageId: "msg-a2", sessionId: sessionA,
                model: "claude-sonnet-5", timestamp: t0.addingTimeInterval(60), cwd: cwdA,
                inputTokens: 200, outputTokens: 80),
        ], to: fileA)

        try fixture.write([
            TranscriptFixture.assistantLine(
                uuid: "uuid-b1", messageId: "msg-b1", sessionId: sessionB,
                model: "claude-haiku-4-5-20251001", timestamp: t0.addingTimeInterval(120), cwd: cwdB,
                inputTokens: 50, outputTokens: 25),
        ], to: fileB)

        try fixture.write([
            TranscriptFixture.assistantLine(
                uuid: "uuid-s1", messageId: "msg-s1", sessionId: sessionA,
                model: "claude-sonnet-5", timestamp: t0.addingTimeInterval(180), cwd: cwdA,
                inputTokens: 300, outputTokens: 150,
                attributionAgent: "explore", attributionSkill: "deepsearch"),
            // Same message.id as the session transcript's second turn.
            TranscriptFixture.assistantLine(
                uuid: "uuid-a2-copy", messageId: "msg-a2", sessionId: sessionA,
                model: "claude-sonnet-5", timestamp: t0.addingTimeInterval(60), cwd: cwdA,
                inputTokens: 200, outputTokens: 80),
        ], to: fileSub)
    }

    func testScanReadsBothSessionAndSubagentTranscripts() async throws {
        let scanner = TranscriptScanner(paths: fixture.paths)
        let result = await scanner.scan()

        XCTAssertEqual(result.events.count, 4, "5 assistant lines minus the duplicated message.id")
        XCTAssertEqual(Set(result.events.map(\.id)), ["uuid-a1", "uuid-a2", "uuid-b1", "uuid-s1"])
        XCTAssertEqual(Set(result.events.map(\.sessionId)), [sessionA, sessionB])

        let subagentEvent = try XCTUnwrap(result.events.first { $0.id == "uuid-s1" })
        XCTAssertEqual(subagentEvent.attributionAgent, "explore")
        XCTAssertEqual(subagentEvent.attributionSkill, "deepsearch")
        XCTAssertEqual(subagentEvent.cwd, cwdA)

        let opusEvent = try XCTUnwrap(result.events.first { $0.id == "uuid-a1" })
        XCTAssertEqual(opusEvent.inputTokens, 1_000)
        XCTAssertEqual(opusEvent.outputTokens, 500)
        XCTAssertEqual(opusEvent.cacheReadTokens, 2_000)
        XCTAssertEqual(opusEvent.cacheCreationTokens, 100)
        XCTAssertEqual(opusEvent.timestamp, t0)
    }

    func testDuplicateMessageIdIsCountedOnce() async throws {
        let scanner = TranscriptScanner(paths: fixture.paths)
        let result = await scanner.scan()

        XCTAssertEqual(result.events.filter { $0.messageId == "msg-a2" }.count, 1)
        // The session transcript sorts before its `subagents/` subdirectory, so its copy wins.
        XCTAssertEqual(result.events.first { $0.messageId == "msg-a2" }?.id, "uuid-a2")
        // Both copies were parsed; only the flattened list is deduped.
        XCTAssertEqual(result.newEvents.count, 5)
    }

    func testSessionTitleComesFromAITitleLine() async throws {
        let scanner = TranscriptScanner(paths: fixture.paths)
        let result = await scanner.scan()

        let info = try XCTUnwrap(result.sessionInfo[sessionA])
        XCTAssertEqual(info.title, "Portage d'UsageKit")
        XCTAssertEqual(info.cwd, cwdA)
        XCTAssertEqual(info.displayName(fallback: sessionA), "Portage d'UsageKit")

        let infoB = try XCTUnwrap(result.sessionInfo[sessionB])
        XCTAssertNil(infoB.title)
        XCTAssertEqual(infoB.displayName(fallback: sessionB), "sess-b")
    }

    func testIncrementalScanOnlyReadsAppendedBytes() async throws {
        let scanner = TranscriptScanner(paths: fixture.paths)
        let first = await scanner.scan()
        XCTAssertEqual(first.events.count, 4)
        XCTAssertGreaterThan(first.bytesRead, 0)

        // Nothing changed: no bytes read, no new events.
        let unchanged = await scanner.scan()
        XCTAssertEqual(unchanged.bytesRead, 0)
        XCTAssertTrue(unchanged.newEvents.isEmpty)
        XCTAssertEqual(unchanged.events.count, 4)

        let appended = TranscriptFixture.assistantLine(
            uuid: "uuid-a3", messageId: "msg-a3", sessionId: sessionA,
            model: "claude-fable-5-1", timestamp: t0.addingTimeInterval(600), cwd: cwdA,
            inputTokens: 10, outputTokens: 20)
        try fixture.append(appended, to: fileA)

        let second = await scanner.scan()
        XCTAssertEqual(second.newEvents.map(\.id), ["uuid-a3"], "only the appended line is parsed")
        XCTAssertEqual(second.bytesRead, appended.utf8.count + 1, "exactly the appended bytes")
        XCTAssertEqual(second.events.count, 5)
    }

    func testPartialLineIsNotConsumedUntilComplete() async throws {
        let scanner = TranscriptScanner(paths: fixture.paths)
        _ = await scanner.scan()

        let line = TranscriptFixture.assistantLine(
            uuid: "uuid-a4", messageId: "msg-a4", sessionId: sessionA,
            model: "claude-sonnet-5", timestamp: t0.addingTimeInterval(700), cwd: cwdA,
            inputTokens: 5, outputTokens: 5)
        let half = String(line.prefix(line.count / 2))
        try fixture.appendPartial(half, to: fileA)

        let midWrite = await scanner.scan()
        XCTAssertTrue(midWrite.newEvents.isEmpty, "an incomplete line yields no event")
        XCTAssertEqual(midWrite.events.count, 4)

        try fixture.appendPartial(String(line.dropFirst(half.count)) + "\n", to: fileA)
        let complete = await scanner.scan()
        XCTAssertEqual(complete.newEvents.map(\.id), ["uuid-a4"])
        XCTAssertEqual(complete.events.count, 5)
    }

    func testCacheIsPersistedUnderAppSupportAndResetClearsIt() async throws {
        let scanner = TranscriptScanner(paths: fixture.paths)
        _ = await scanner.scan()

        let cacheURL = await scanner.cacheFileURL
        XCTAssertEqual(cacheURL, fixture.paths.appSupportDir.appendingPathComponent("scan-cache.json"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path))

        // A fresh scanner sharing the same paths reloads the cache instead of re-reading.
        let warm = TranscriptScanner(paths: fixture.paths)
        let warmResult = await warm.scan()
        XCTAssertEqual(warmResult.events.count, 4)
        XCTAssertEqual(warmResult.bytesRead, 0)

        await warm.reset()
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
        let afterReset = await warm.scan()
        XCTAssertEqual(afterReset.events.count, 4)
        XCTAssertGreaterThan(afterReset.bytesRead, 0, "reset forces a full re-read")
    }

    func testServiceRefreshReturnsEventsAndFailsOnMissingProjectsDir() async throws {
        let service = UsageService(paths: fixture.paths)
        let events = try await service.refresh()
        XCTAssertEqual(events.count, 4)
        let cached = await service.lastEvents
        XCTAssertEqual(cached.count, 4)

        let snapshot = await service.snapshot(filters: UsageFilters(range: .all), pricing: .default)
        XCTAssertEqual(snapshot.totals.turnCount, 4)

        let empty = try TranscriptFixture()
        try FileManager.default.removeItem(at: empty.paths.projectsDir)
        let broken = UsageService(paths: empty.paths)
        do {
            _ = try await broken.refresh()
            XCTFail("expected projectsDirectoryMissing")
        } catch let error as UsageServiceError {
            guard case .projectsDirectoryMissing = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }
}
