import Foundation

/// Watches one or more directories with kernel events and emits a debounced
/// tick whenever something changes underneath them. Not recursive: pass the
/// directories whose direct entries matter (the callers re-scan anyway).
public final class DirectoryWatcher: @unchecked Sendable {
    public let changes: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private var sources: [DispatchSourceFileSystemObject] = []
    private var descriptors: [Int32] = []
    private let queue = DispatchQueue(label: "fr.vincentlauriat.claudecockpit.watcher")
    private var pending: DispatchWorkItem?
    private let debounce: TimeInterval

    public init(directories: [URL], debounce: TimeInterval = 0.5) {
        self.debounce = debounce
        var cont: AsyncStream<Void>.Continuation!
        changes = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { cont = $0 }
        continuation = cont
        for dir in directories {
            let fd = open(dir.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            descriptors.append(fd)
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .rename, .delete, .attrib, .extend],
                queue: queue)
            source.setEventHandler { [weak self] in self?.schedule() }
            source.resume()
            sources.append(source)
        }
    }

    private func schedule() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.continuation.yield() }
        pending = item
        queue.asyncAfter(deadline: .now() + debounce, execute: item)
    }

    public func stop() {
        sources.forEach { $0.cancel() }
        sources.removeAll()
        descriptors.forEach { close($0) }
        descriptors.removeAll()
        continuation.finish()
    }

    deinit { stop() }
}
