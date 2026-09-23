// CockpitShared — see docs/superpowers/specs/2026-09-23-sessions-viewer.md
import Foundation
import CoreServices

/// Watches directory trees **recursively** and emits the paths that changed,
/// debounced and deduplicated.
///
/// ## Why this exists next to `DirectoryWatcher`
/// `DirectoryWatcher` arms a `DispatchSource` per directory and is explicitly
/// not recursive. That is the right tool for a handful of known directories
/// (`~/.claude/skills`, …), and the wrong one for `~/.claude/projects`, where
/// the writes happen one level down in `<project>/<session>.jsonl`. Measured on
/// 2026-09-23: appending a line to a nested file does **not** wake a
/// `DispatchSource` armed on the root, while an `FSEventStream` created with
/// `kFSEventStreamCreateFlagFileEvents` sees it. Hence FSEvents here.
///
/// ## Why it yields paths
/// The transcript tree is ~900 MB. A bare "something changed" tick would force
/// a full walk on every keystroke of an active session; the changed paths let
/// the caller re-read only those files. The polling fallback has nothing to
/// name, so it yields an empty array, which callers must read as "re-scan
/// everything".
///
/// ## Ownership
/// FSEvents needs a raw pointer for its C callback, so the watcher retains
/// itself while the stream is live. That retain is released in `stop()`, so
/// **`deinit` alone never frees a started watcher** — its owner must call
/// `stop()`, as `DBWatcher` already documents for the same reason.
public final class RecursiveWatcher: @unchecked Sendable {

    /// Debounced batches of changed paths. Buffers the newest batch only: a
    /// consumer still indexing coalesces whatever happened meanwhile.
    ///
    /// An **empty** batch means "unknown, re-scan": it comes from the polling
    /// fallback or from an FSEvents notification that asked for a full rescan.
    public let changes: AsyncStream<[String]>

    private let roots: [URL]
    private let filter: (@Sendable (String) -> Bool)?
    private let debounce: TimeInterval
    private let pollingInterval: TimeInterval?
    private let queue = DispatchQueue(label: "fr.vincentlauriat.claudecockpit.recursive.watcher")
    private let continuation: AsyncStream<[String]>.Continuation
    /// Marks `queue`, so `synchronized` can tell "already there" from "elsewhere".
    private static let queueKey = DispatchSpecificKey<UInt8>()

    private var eventStream: FSEventStreamRef?
    private var timer: DispatchSourceTimer?
    private var pending: DispatchWorkItem?
    /// Paths accumulated since the last emission, deduplicated.
    private var batch: Set<String> = []
    /// Set when FSEvents reports it dropped events: the next tick must be empty
    /// so the caller falls back to a full scan instead of trusting `batch`.
    private var needsFullRescan = false
    private var retainedSelf: UnsafeMutableRawPointer?
    private var started = false

    /// - Parameters:
    ///   - roots: directory trees to watch; each is observed recursively. A root
    ///     that does not exist yet is still accepted — FSEvents delivers events
    ///     once it appears.
    ///   - filter: keeps only the paths worth reporting, e.g. `.hasSuffix(".jsonl")`.
    ///     A path rejected by the filter never wakes the consumer.
    ///   - debounce: how long to coalesce a burst of file-system events.
    ///   - pollingInterval: fallback tick, or `nil` to rely on FSEvents alone.
    public init(
        roots: [URL],
        filter: (@Sendable (String) -> Bool)? = nil,
        debounce: TimeInterval = 1.0,
        pollingInterval: TimeInterval? = 300
    ) {
        self.roots = roots
        self.filter = filter
        self.debounce = debounce
        self.pollingInterval = pollingInterval
        var captured: AsyncStream<[String]>.Continuation!
        changes = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { captured = $0 }
        continuation = captured
        queue.setSpecific(key: Self.queueKey, value: 1)
    }

    /// Runs `body` with exclusive access to the watcher's state.
    ///
    /// `queue.sync` from `queue` itself deadlocks unconditionally, and `stop()`
    /// is reachable from an owner's `deinit` on any thread. The specific-key
    /// probe turns that case into a direct call instead of a hang.
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
            guard !started, !roots.isEmpty else { return }
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
                Unmanaged<RecursiveWatcher>.fromOpaque(retainedSelf).release()
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

        let callback: FSEventStreamCallback = { _, info, count, rawPaths, rawFlags, _ in
            guard let info,
                  let paths = unsafeBitCast(rawPaths, to: NSArray.self) as? [String]
            else { return }
            let watcher = Unmanaged<RecursiveWatcher>.fromOpaque(info).takeUnretainedValue()

            var changed: [String] = []
            var mustRescan = false
            for index in 0..<count where index < paths.count {
                let flags = Int(rawFlags[index])
                // The kernel coalesced or dropped events: the path list no longer
                // describes everything that happened, so ask for a full rescan.
                if flags & (kFSEventStreamEventFlagMustScanSubDirs
                    | kFSEventStreamEventFlagKernelDropped
                    | kFSEventStreamEventFlagUserDropped) != 0 {
                    mustRescan = true
                }
                changed.append(paths[index])
            }
            watcher.accumulate(changed, mustRescan: mustRescan)
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            roots.map(\.path) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            debounce,
            UInt32(kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagNoDefer)
        ) else {
            // FSEvents refused the paths — the polling fallback still covers us.
            Unmanaged<RecursiveWatcher>.fromOpaque(selfPointer).release()
            retainedSelf = nil
            return
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        eventStream = stream
    }

    /// Called on `queue` from the FSEvents callback.
    private func accumulate(_ paths: [String], mustRescan: Bool) {
        let kept = filter.map { keep in paths.filter(keep) } ?? paths
        // A burst that the filter rejects entirely must not wake the consumer,
        // but a dropped-events notification must, even with nothing to name.
        guard !kept.isEmpty || mustRescan else { return }
        batch.formUnion(kept)
        if mustRescan { needsFullRescan = true }
        schedule()
    }

    // MARK: - Polling fallback

    /// Uses a `DispatchSourceTimer` rather than a `Timer`, so the watcher works
    /// without a run loop — including inside tests and background actors.
    private func startPolling() {
        guard let pollingInterval else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + pollingInterval, repeating: pollingInterval)
        source.setEventHandler { [weak self] in self?.continuation.yield([]) }
        source.resume()
        timer = source
    }

    // MARK: - Debounce

    /// Called on `queue`. Emits the accumulated batch once the burst settles.
    private func schedule() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let payload = self.needsFullRescan ? [] : Array(self.batch)
            self.batch.removeAll(keepingCapacity: true)
            self.needsFullRescan = false
            self.continuation.yield(payload)
        }
        pending = item
        queue.asyncAfter(deadline: .now() + debounce, execute: item)
    }
}
