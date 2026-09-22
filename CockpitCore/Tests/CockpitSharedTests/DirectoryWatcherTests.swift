import XCTest
@testable import CockpitShared

/// Counts the ticks a watcher emits. A single task consumes the stream — `AsyncStream` has
/// one consumer — and the tests wait on this counter instead of iterating themselves.
private final class TickCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func bump() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}

final class DirectoryWatcherTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DirectoryWatcherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    /// A fresh user has none of the watched directories, so `open(2)` fails on every one of
    /// them and no kernel source can be armed. The stream must still tick, or the store's
    /// `for await` blocks forever with no fallback.
    func testWatcherOnMissingDirectoryStillTicks() async throws {
        let missing = root.appendingPathComponent("never-created", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))

        let watcher = DirectoryWatcher(directories: [missing], debounce: 0.05, pollingInterval: 0.2)
        defer { watcher.stop() }
        let ticks = consume(watcher)

        try await waitForTick(ticks, above: 0, message: "no fallback tick for a missing directory")
    }

    /// Once a missing directory appears, the poller attaches a real kernel source to it, so a
    /// write inside it produces a tick.
    func testWatcherAttachesRealSourceWhenTheDirectoryAppears() async throws {
        let late = root.appendingPathComponent("late", isDirectory: true)
        let watcher = DirectoryWatcher(directories: [late], debounce: 0.05, pollingInterval: 0.2)
        defer { watcher.stop() }
        let ticks = consume(watcher)

        try FileManager.default.createDirectory(at: late, withIntermediateDirectories: true)
        try await waitForTick(ticks, above: 0, message: "no tick after the directory was created")

        // Let the poller settle: once every directory is watched it cancels itself, so the
        // next tick can only come from the kernel source.
        try await Task.sleep(for: .milliseconds(600))
        let baseline = ticks.count
        try "bonjour".write(to: late.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try await waitForTick(ticks, above: baseline, message: "no tick after a file was written")
    }

    /// An existing directory keeps the plain kernel-event behaviour, with no polling involved.
    func testWatcherOnExistingDirectoryTicksOnWrite() async throws {
        let watcher = DirectoryWatcher(directories: [root], debounce: 0.05, pollingInterval: 30)
        defer { watcher.stop() }
        let ticks = consume(watcher)

        try "bonjour".write(to: root.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)
        try await waitForTick(ticks, above: 0, message: "no tick after a file was written")
    }

    // MARK: - Helpers

    private func consume(_ watcher: DirectoryWatcher) -> TickCounter {
        let counter = TickCounter()
        let stream = watcher.changes
        Task.detached {
            for await _ in stream { counter.bump() }
        }
        return counter
    }

    /// Fails rather than hangs: bounded by an explicit timeout.
    private func waitForTick(
        _ counter: TickCounter,
        above baseline: Int,
        timeout: TimeInterval = 3,
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if counter.count > baseline { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail(message, file: file, line: line)
    }
}
