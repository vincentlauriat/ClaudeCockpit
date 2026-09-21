// RTKKit — see docs/superpowers/specs/2026-09-21-claude-cockpit-design.md
import Foundation
import CoreServices

/// Watches the directory holding rtk's `history.db` and emits a debounced tick
/// on every change to the database, its WAL, or its shared-memory file.
///
/// Two complementary layers, both feeding the same `changes` stream:
/// - **FSEvents** (primary): kernel notifications, filtered to `history.db*`.
/// - **A periodic timer** (fallback): fires unconditionally, so the cockpit
///   still refreshes on volumes where FSEvents is unavailable.
///
/// Bursts are coalesced: rtk touches `-wal`, `-shm` and `history.db` within a
/// few milliseconds of each other, which would otherwise trigger three reads.
///
/// ## Ownership
/// FSEvents needs a raw pointer for its C callback, so the watcher retains
/// itself with `Unmanaged.passRetained` while the stream is live. That retain
/// is released in `stop()`, which means **`deinit` alone never frees a started
/// watcher** — its owner must call `stop()`. `RTKService` does so from its own
/// `deinit` and from `changes`'s termination handler.
public final class DBWatcher: @unchecked Sendable {

    /// Debounced change notifications. Buffers the newest tick only: a consumer
    /// that is busy reading the database coalesces whatever happened meanwhile.
    public let changes: AsyncStream<Void>

    private let directory: URL
    private let debounce: TimeInterval
    private let pollingInterval: TimeInterval?
    private let queue = DispatchQueue(label: "fr.vincentlauriat.claudecockpit.rtk.watcher")
    private let continuation: AsyncStream<Void>.Continuation
    /// Marks `queue`, so `synchronized` can tell "already there" from "elsewhere".
    private static let queueKey = DispatchSpecificKey<UInt8>()

    private var eventStream: FSEventStreamRef?
    private var timer: DispatchSourceTimer?
    private var pending: DispatchWorkItem?
    /// Retained self-pointer handed to FSEvents, released in `stop()`.
    private var retainedSelf: UnsafeMutableRawPointer?
    private var started = false

    /// - Parameters:
    ///   - databaseURL: the `history.db` to watch; its parent directory is observed.
    ///   - debounce: how long to coalesce a burst of file-system events.
    ///   - pollingInterval: fallback tick, or `nil` to rely on FSEvents alone.
    public init(databaseURL: URL, debounce: TimeInterval = 0.3, pollingInterval: TimeInterval? = 30) {
        self.directory = databaseURL.deletingLastPathComponent()
        self.debounce = debounce
        self.pollingInterval = pollingInterval
        var captured: AsyncStream<Void>.Continuation!
        changes = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { captured = $0 }
        continuation = captured
        queue.setSpecific(key: Self.queueKey, value: 1)
    }

    /// Runs `body` with exclusive access to the watcher's state.
    ///
    /// `queue.sync` from `queue` itself is an unconditional deadlock, and
    /// `stop()` is reachable from `RTKService.deinit`, which can run on any
    /// thread — including one already inside `queue`. The specific-key probe
    /// makes that case a direct call instead of a hang.
    private func synchronized(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            body()
        } else {
            queue.sync(execute: body)
        }
    }

    /// Starts both layers. Calling it twice is a no-op.
    public func start() {
        synchronized {
            guard !started else { return }
            started = true
            startFSEvents()
            startPolling()
        }
    }

    /// Stops both layers, finishes `changes`, and balances the FSEvents retain.
    /// Safe to call repeatedly and from any thread.
    public func stop() {
        synchronized {
            pending?.cancel()
            pending = nil
            timer?.cancel()
            timer = nil
            if let stream = eventStream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                eventStream = nil
            }
            if let retainedSelf {
                Unmanaged<DBWatcher>.fromOpaque(retainedSelf).release()
                self.retainedSelf = nil
            }
            started = false
        }
        continuation.finish()
    }

    // MARK: - FSEvents

    private func startFSEvents() {
        let selfPointer = Unmanaged.passRetained(self).toOpaque()
        retainedSelf = selfPointer

        var context = FSEventStreamContext(
            version: 0,
            info: selfPointer,
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, count, rawPaths, _, _ in
            guard let info,
                  let paths = unsafeBitCast(rawPaths, to: NSArray.self) as? [String]
            else { return }
            // rtk writes the WAL first, so those touches matter as much as the .db.
            let relevant = paths.prefix(count).contains { path in
                let name = (path as NSString).lastPathComponent
                return name.hasPrefix("history.db")
            }
            guard relevant else { return }
            Unmanaged<DBWatcher>.fromOpaque(info).takeUnretainedValue().schedule()
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [directory.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            debounce,
            UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        ) else {
            // FSEvents refused the path — the polling fallback still covers us.
            Unmanaged<DBWatcher>.fromOpaque(selfPointer).release()
            retainedSelf = nil
            return
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        eventStream = stream
    }

    // MARK: - Polling fallback

    /// Uses a `DispatchSourceTimer` rather than a `Timer`, so the watcher works
    /// without a run loop — including inside tests and background actors.
    private func startPolling() {
        guard let pollingInterval else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + pollingInterval, repeating: pollingInterval)
        source.setEventHandler { [weak self] in self?.continuation.yield() }
        source.resume()
        timer = source
    }

    // MARK: - Debounce

    /// Called on `queue` from the FSEvents callback.
    private func schedule() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.continuation.yield() }
        pending = item
        queue.asyncAfter(deadline: .now() + debounce, execute: item)
    }
}
