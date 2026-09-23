import XCTest
@testable import CockpitShared

/// Collects the batches a `RecursiveWatcher` emits. One task consumes the stream —
/// `AsyncStream` has a single consumer — and the tests wait on this collector.
private final class BatchCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var batches: [[String]] = []

    var all: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return batches
    }

    var paths: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(batches.flatMap { $0 })
    }

    func append(_ batch: [String]) {
        lock.lock()
        batches.append(batch)
        lock.unlock()
    }
}

final class RecursiveWatcherTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecursiveWatcherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    /// Waits until `condition` holds or the deadline passes. FSEvents latency is a
    /// property of the kernel, not of the code under test, so the tests poll instead
    /// of sleeping for a fixed, and inevitably flaky, duration.
    private func wait(
        upTo seconds: TimeInterval = 8,
        for condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// The reason this class exists. `DirectoryWatcher` arms a `DispatchSource` on the
    /// directories it is given and never sees a write one level down, which is exactly
    /// where Claude Code appends its turns: `<project>/<session>.jsonl`. The append must
    /// reach the consumer, and the batch must name the file so the indexer can re-read
    /// only that one.
    func testAppendToNestedFileIsReportedWithItsPath() async throws {
        let nested = root.appendingPathComponent("project-x", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let transcript = nested.appendingPathComponent("session.jsonl")
        // The file exists before watching starts: this is an append to an existing
        // transcript, not a creation, and the two are different FSEvents flags.
        try Data("first\n".utf8).write(to: transcript)

        let collector = BatchCollector()
        let watcher = RecursiveWatcher(
            roots: [root],
            filter: { $0.hasSuffix(".jsonl") },
            debounce: 0.2,
            pollingInterval: nil // no fallback: this must be FSEvents or nothing
        )
        let consumer = Task { for await batch in watcher.changes { collector.append(batch) } }
        defer { watcher.stop(); consumer.cancel() }
        watcher.start()
        // Let the stream arm before writing, or the event predates the subscription.
        try await Task.sleep(nanoseconds: 700_000_000)

        let handle = try FileHandle(forWritingTo: transcript)
        handle.seekToEndOfFile()
        handle.write(Data("appended\n".utf8))
        try handle.close()

        await wait { !collector.all.isEmpty }
        let seen = collector.paths
        XCTAssertFalse(collector.all.isEmpty, "a nested append must wake the watcher")
        // Compare resolved paths: /var and /private/var are the same directory.
        let expected = transcript.resolvingSymlinksInPath().path
        XCTAssertTrue(
            seen.contains { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == expected },
            "the batch must name the changed transcript, got \(seen)")
    }

    /// The filter is what keeps a busy tree from waking the indexer: Claude Code writes
    /// plenty of neighbours that are not transcripts.
    func testPathsRejectedByTheFilterDoNotWakeTheConsumer() async throws {
        let collector = BatchCollector()
        let watcher = RecursiveWatcher(
            roots: [root],
            filter: { $0.hasSuffix(".jsonl") },
            debounce: 0.2,
            pollingInterval: nil
        )
        let consumer = Task { for await batch in watcher.changes { collector.append(batch) } }
        defer { watcher.stop(); consumer.cancel() }
        watcher.start()
        try await Task.sleep(nanoseconds: 700_000_000)

        try Data("noise".utf8).write(to: root.appendingPathComponent("scan-cache.json"))
        try await Task.sleep(nanoseconds: 1_500_000_000)

        XCTAssertTrue(collector.all.isEmpty, "a non-transcript write must stay silent, got \(collector.all)")
    }

    /// Without FSEvents — an unsupported volume, a refused path — the consumer would
    /// otherwise wait forever. The fallback yields an empty batch, the agreed signal
    /// for "unknown, re-scan everything".
    func testPollingFallbackYieldsAnEmptyBatch() async throws {
        let collector = BatchCollector()
        let watcher = RecursiveWatcher(
            roots: [root],
            filter: { _ in false }, // nothing can ever pass: only the timer can tick
            debounce: 0.1,
            pollingInterval: 0.3
        )
        let consumer = Task { for await batch in watcher.changes { collector.append(batch) } }
        defer { watcher.stop(); consumer.cancel() }
        watcher.start()

        await wait { !collector.all.isEmpty }
        XCTAssertEqual(collector.all.first, [], "the fallback tick carries no path")
    }

    /// `stop()` balances the FSEvents retain and finishes the stream; a consumer must
    /// leave its `for await` instead of hanging on shutdown.
    func testStopFinishesTheStream() async throws {
        let watcher = RecursiveWatcher(roots: [root], debounce: 0.1, pollingInterval: nil)
        let finished = BatchCollector()
        let consumer = Task {
            for await batch in watcher.changes { finished.append(batch) }
            return true
        }
        watcher.start()
        watcher.stop()
        watcher.stop() // twice on purpose: must stay a no-op

        let ended = await consumer.value
        XCTAssertTrue(ended)
    }
}
