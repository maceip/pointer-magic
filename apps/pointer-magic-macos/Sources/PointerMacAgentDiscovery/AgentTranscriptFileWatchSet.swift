import Darwin
import Dispatch
import Foundation

/// A bounded set of vnode watches for transcript files proven open by the latest
/// process census. These are latency hints only; periodic census remains authoritative.
actor AgentTranscriptFileWatchSet {
    private final class Entry: @unchecked Sendable {
        let source: DispatchSourceFileSystemObject

        init(source: DispatchSourceFileSystemObject) {
            self.source = source
        }

        func cancel() {
            source.cancel()
        }
    }

    private let queue = DispatchQueue(
        label: "com.magicpointer.agent-transcript-watches",
        qos: .userInitiated
    )
    private var entries: [String: Entry] = [:]

    deinit {
        for entry in entries.values {
            entry.cancel()
        }
    }

    func reconcile(
        _ canonicalPaths: Set<AgentCanonicalTranscriptPath>,
        maximumCount: Int,
        onChange: @escaping @Sendable (String) -> Void
    ) {
        reconcilePaths(
            Set(canonicalPaths.map(\.canonicalPath)),
            maximumCount: maximumCount,
            onChange: onChange
        )
    }

    /// Watches only paths already validated and derived from exact process-open
    /// provider stores. Cursor includes its session directory so WAL replacement is
    /// observable; JSONL providers normally supply only the transcript file.
    func reconcilePaths(
        _ paths: Set<String>,
        maximumCount: Int,
        onChange: @escaping @Sendable (String) -> Void
    ) {
        let desired = Set(
            paths
                .sorted()
                .prefix(max(0, maximumCount))
        )

        for path in entries.keys where !desired.contains(path) {
            entries.removeValue(forKey: path)?.cancel()
        }

        for path in desired where entries[path] == nil {
            guard let entry = makeEntry(path: path, onChange: onChange) else {
                continue
            }
            entries[path] = entry
        }
    }

    func stop() {
        let current = entries.values
        entries.removeAll(keepingCapacity: false)
        for entry in current {
            entry.cancel()
        }
    }

    func watchedPaths() -> Set<String> {
        Set(entries.keys)
    }

    private func makeEntry(
        path: String,
        onChange: @escaping @Sendable (String) -> Void
    ) -> Entry? {
        let descriptor = open(path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }

        var metadata = Darwin.stat()
        guard fstat(descriptor, &metadata) == 0 else {
            close(descriptor)
            return nil
        }
        let kind = metadata.st_mode & S_IFMT
        guard kind == S_IFREG || kind == S_IFDIR else {
            close(descriptor)
            return nil
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename, .revoke],
            queue: queue
        )
        source.setEventHandler {
            onChange(path)
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        return Entry(source: source)
    }
}
