import Foundation

/// Watches one or more directories with kernel events and emits a debounced
/// tick whenever something changes underneath them. Not recursive: pass the
/// directories whose direct entries matter (the callers re-scan anyway).
///
/// A directory that does not exist yet cannot be watched — `open(2)` fails and
/// it is skipped. When *none* of the given directories exist (a fresh user with
/// no `~/.claude/skills`, no library), the watcher would otherwise never emit
/// anything and a `for await` over `changes` would block forever. In that case
/// a polling timer takes over: it yields every `pollingInterval` seconds and
/// re-tries `open(2)` on each tick, attaching real watchers as the directories
/// appear and stopping once they all have one.
public final class DirectoryWatcher: @unchecked Sendable {
    public let changes: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let directories: [URL]
    private let queue = DispatchQueue(label: "fr.vincentlauriat.claudecockpit.watcher")
    private let debounce: TimeInterval
    private let pollingInterval: TimeInterval

    /// Guards every mutable field below: `stop()` may be called from any thread
    /// while the polling timer is attaching sources on `queue`.
    private let lock = NSLock()
    private var sources: [DispatchSourceFileSystemObject] = []
    private var descriptors: [Int32] = []
    private var watchedPaths: Set<String> = []
    private var poller: DispatchSourceTimer?
    private var pending: DispatchWorkItem?
    private var stopped = false

    /// - Parameters:
    ///   - directories: the directories to watch; missing ones are polled for.
    ///   - debounce: how long to coalesce a burst of kernel events.
    ///   - pollingInterval: fallback tick period used when no directory could
    ///     be watched. Lower it in tests.
    public init(directories: [URL], debounce: TimeInterval = 0.5, pollingInterval: TimeInterval = 60) {
        self.directories = directories
        self.debounce = debounce
        self.pollingInterval = pollingInterval
        var cont: AsyncStream<Void>.Continuation!
        changes = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { cont = $0 }
        continuation = cont

        lock.lock()
        for dir in directories { attachLocked(dir) }
        let needsPolling = sources.isEmpty
        if needsPolling { startPollingLocked() }
        lock.unlock()
    }

    /// Opens `dir` and arms a kernel source on it. Caller holds `lock`.
    private func attachLocked(_ dir: URL) {
        guard !stopped, !watchedPaths.contains(dir.path) else { return }
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        descriptors.append(fd)
        watchedPaths.insert(dir.path)
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .attrib, .extend],
            queue: queue)
        source.setEventHandler { [weak self] in self?.schedule() }
        source.resume()
        sources.append(source)
    }

    /// Caller holds `lock`.
    private func startPollingLocked() {
        guard !stopped, poller == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + pollingInterval, repeating: pollingInterval)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        poller = timer
    }

    /// One fallback tick: retry the directories that are still unwatched, stop
    /// polling once every one of them has a real source, and yield either way
    /// so the caller re-scans.
    private func poll() {
        lock.lock()
        guard !stopped else { return lock.unlock() }
        for dir in directories { attachLocked(dir) }
        if watchedPaths.count == directories.count, !directories.isEmpty {
            poller?.cancel()
            poller = nil
        }
        lock.unlock()
        continuation.yield()
    }

    private func schedule() {
        lock.lock()
        guard !stopped else { return lock.unlock() }
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.continuation.yield() }
        pending = item
        lock.unlock()
        queue.asyncAfter(deadline: .now() + debounce, execute: item)
    }

    public func stop() {
        lock.lock()
        stopped = true
        pending?.cancel()
        pending = nil
        poller?.cancel()
        poller = nil
        let openSources = sources
        let openDescriptors = descriptors
        sources.removeAll()
        descriptors.removeAll()
        watchedPaths.removeAll()
        lock.unlock()

        openSources.forEach { $0.cancel() }
        openDescriptors.forEach { close($0) }
        continuation.finish()
    }

    deinit { stop() }
}
