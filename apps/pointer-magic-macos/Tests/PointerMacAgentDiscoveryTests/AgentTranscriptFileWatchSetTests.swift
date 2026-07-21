import Foundation
@testable import PointerMacAgentDiscovery
import Testing

@Suite("Exact transcript file watches")
struct AgentTranscriptFileWatchSetTests {
    private actor EventRecorder {
        private var paths: [String] = []

        func record(_ path: String) {
            paths.append(path)
        }

        func contains(_ path: String) -> Bool {
            paths.contains(path)
        }
    }

    @Test("A write to an exact watched file produces a prompt wake-up hint")
    func writeProducesHint() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let watches = AgentTranscriptFileWatchSet()
        let recorder = EventRecorder()

        await watches.reconcile(
            [fixture.canonical],
            maximumCount: 4
        ) { path in
            Task { await recorder.record(path) }
        }
        try fixture.append("{\"type\":\"event_msg\"}\n")

        let observed = await eventually {
            await recorder.contains(fixture.path)
        }
        #expect(observed)
        await watches.stop()
    }

    @Test("Every census reconciliation removes stale watches and stop removes all")
    func reconcileAndStop() async throws {
        let first = try Fixture()
        let second = try Fixture()
        defer {
            first.remove()
            second.remove()
        }
        let watches = AgentTranscriptFileWatchSet()

        await watches.reconcile(
            [first.canonical, second.canonical],
            maximumCount: 4,
            onChange: { _ in }
        )
        #expect(await watches.watchedPaths() == [first.path, second.path])

        await watches.reconcile(
            [second.canonical],
            maximumCount: 4,
            onChange: { _ in }
        )
        #expect(await watches.watchedPaths() == [second.path])

        await watches.stop()
        #expect(await watches.watchedPaths().isEmpty)
    }

    private func eventually(
        timeoutNs: UInt64 = 1_000_000_000,
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let started = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - started < timeoutNs {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await condition()
    }

    private final class Fixture: @unchecked Sendable {
        let directory: URL
        let path: String
        let canonical: AgentCanonicalTranscriptPath

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let url = directory.appendingPathComponent("transcript.jsonl")
            guard FileManager.default.createFile(atPath: url.path, contents: Data()) else {
                throw FixtureError.couldNotCreateFile
            }
            path = url.path
            canonical = AgentCanonicalTranscriptPath(
                provider: .codex,
                canonicalPath: path,
                providerSessionID: UUID().uuidString.lowercased()
            )
        }

        func append(_ value: String) throws {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(value.utf8))
            try handle.synchronize()
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private enum FixtureError: Error {
        case couldNotCreateFile
    }
}
