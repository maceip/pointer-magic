import Foundation

@MainActor
final class BroadcastHub<Element: Sendable> {
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]

    func stream(
        bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy
    ) -> AsyncStream<Element> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: bufferingPolicy) { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.continuations[id] = nil
                }
            }
        }
    }

    func yield(_ value: Element) {
        for continuation in continuations.values {
            continuation.yield(value)
        }
    }

    func finish() {
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll(keepingCapacity: false)
    }
}
