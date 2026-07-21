import Foundation
@testable import PointerMacAgentDiscovery
import Testing

@Suite("Agent transcript discovery")
struct AgentTranscriptParserTests {
    @Test("Only canonical provider transcript layouts are accepted")
    func canonicalLayouts() {
        let home = NSHomeDirectory()
        let codexID = "11111111-1111-1111-1111-111111111111"
        let claudeID = "22222222-2222-2222-2222-222222222222"

        #expect(AgentCanonicalTranscriptPath.classify(
            "\(home)/.codex/sessions/2026/07/14/rollout-2026-07-14T12-00-00-\(codexID).jsonl"
        )?.providerSessionID == codexID)
        #expect(AgentCanonicalTranscriptPath.classify(
            "\(home)/.claude/projects/-Users-example-demo/\(claudeID).jsonl"
        )?.providerSessionID == claudeID)
        #expect(AgentCanonicalTranscriptPath.classify(
            "\(home)/.claude/projects/-Users-example-demo/\(claudeID)/subagents/agent-1.jsonl"
        ) == nil)
    }

    @Test("Claude tool results cannot masquerade as human attention")
    func claudeHumanEvidenceIsStrict() throws {
        let id = "22222222-2222-2222-2222-222222222222"
        let toolResult = Data(#"""
        {
          "type":"user",
          "sessionId":"22222222-2222-2222-2222-222222222222",
          "message":{"role":"user","content":"tool output"},
          "cwd":"/tmp/work"
        }
        """#.utf8)
        let toolParsed = try #require(AgentTranscriptParser.parse(
            toolResult,
            provider: .claude,
            pathSessionID: id,
            sourceOffset: 1,
            maximumTextCharacters: 200
        ))
        #expect(toolParsed.event == nil)

        let typed = Data(#"""
        {
          "type":"user",
          "sessionId":"22222222-2222-2222-2222-222222222222",
          "parentUuid":null,
          "isSidechain":false,
          "origin":{"kind":"human"},
          "promptSource":"typed",
          "entrypoint":"cli",
          "message":{"role":"user","content":"Fix the shelf"},
          "timestamp":"2026-07-14T20:00:00.000Z",
          "cwd":"/tmp/work"
        }
        """#.utf8)
        let humanParsed = try #require(AgentTranscriptParser.parse(
            typed,
            provider: .claude,
            pathSessionID: id,
            sourceOffset: 2,
            maximumTextCharacters: 200
        ))
        #expect(humanParsed.event?.kind == .userPrompt)
        #expect(humanParsed.event?.text == "Fix the shelf")
    }

    @Test("Codex event messages provide bounded prompt evidence")
    func codexPrompt() throws {
        let data = Data(#"""
        {
          "timestamp":"2026-07-14T20:00:00.000Z",
          "type":"event_msg",
          "payload":{"type":"user_message","message":"Build the real prototype"}
        }
        """#.utf8)
        let parsed = try #require(AgentTranscriptParser.parse(
            data,
            provider: .codex,
            pathSessionID: "11111111-1111-1111-1111-111111111111",
            sourceOffset: 3,
            maximumTextCharacters: 200
        ))

        #expect(parsed.event?.kind == .userPrompt)
        #expect(parsed.event?.text == "Build the real prototype")
    }

    @Test("An out-of-range external timestamp cannot terminate parsing")
    func outOfRangeTimestampIsRejected() throws {
        let data = Data(#"""
        {
          "timestamp":1e300,
          "type":"event_msg",
          "payload":{"type":"user_message","message":"Keep the app alive"}
        }
        """#.utf8)
        let parsed = try #require(AgentTranscriptParser.parse(
            data,
            provider: .codex,
            pathSessionID: "11111111-1111-1111-1111-111111111111",
            sourceOffset: 4,
            maximumTextCharacters: 200
        ))

        #expect(parsed.event?.text == "Keep the app alive")
        #expect(parsed.event?.timestampUnixNs == nil)
    }

    @Test("Codex local_images are structured and never inferred from placeholder text")
    func codexImageAttachmentsAreStructured() throws {
        let attached = Data(#"""
        {
          "timestamp":"2026-07-14T20:00:00.000Z",
          "type":"event_msg",
          "payload":{
            "type":"user_message",
            "message":"[Image #1] Fix this layout",
            "images":[],
            "local_images":["/Users/test/Desktop/layout.png"]
          }
        }
        """#.utf8)
        let parsed = try #require(AgentTranscriptParser.parse(
            attached,
            provider: .codex,
            pathSessionID: "11111111-1111-1111-1111-111111111111",
            sourceOffset: 44,
            maximumTextCharacters: 200
        ))

        #expect(parsed.event?.text == "[Image #1] Fix this layout")
        #expect(parsed.event?.imageAttachments == [
            AgentTranscriptImageAttachment(
                identifier: "44:0",
                localFilePath: "/Users/test/Desktop/layout.png"
            ),
        ])

        let literal = Data(#"""
        {
          "type":"event_msg",
          "payload":{"type":"user_message","message":"Discuss [Image 1] literally"}
        }
        """#.utf8)
        let literalParsed = try #require(AgentTranscriptParser.parse(
            literal,
            provider: .codex,
            pathSessionID: "11111111-1111-1111-1111-111111111111",
            sourceOffset: 45,
            maximumTextCharacters: 200
        ))
        #expect(literalParsed.event?.imageAttachments.isEmpty == true)
    }

    @Test("An image-only Codex operator turn remains prompt evidence")
    func codexImageOnlyPrompt() throws {
        let data = Data(#"""
        {
          "type":"event_msg",
          "payload":{
            "type":"user_message",
            "message":"",
            "local_images":["/Users/test/Desktop/layout.png"]
          }
        }
        """#.utf8)
        let parsed = try #require(AgentTranscriptParser.parse(
            data,
            provider: .codex,
            pathSessionID: "11111111-1111-1111-1111-111111111111",
            sourceOffset: 46,
            maximumTextCharacters: 200
        ))
        #expect(parsed.event?.kind == .userPrompt)
        #expect(parsed.event?.text == nil)
        #expect(parsed.event?.imageAttachments.count == 1)
    }

    @Test("An oversized Codex record cannot strand later lifecycle events")
    func oversizedCodexRecordMakesBoundedForwardProgress() async throws {
        let fixture = try RegistryFixture(initial: [
            RegistryFixture.sessionMetadata,
            RegistryFixture.taskStarted,
            RegistryFixture.ignoredRecord(payloadBytes: 6 * 1_024),
            RegistryFixture.taskCompleted,
        ].joined())
        defer { fixture.remove() }
        let registry = AgentTranscriptRegistry(configuration: .init(
            maximumReadBytesPerFile: 4 * 1_024,
            startupReplayBytes: 64 * 1_024
        ))

        var result = try #require(await registry.consume(
            fixture.canonical,
            observedAt: 1
        ))
        #expect(result.snapshot.recentEvents.last?.kind == .turnStarted)
        var offsets = [result.snapshot.nextReadOffset]
        var diagnosedOversizedRecord = result.oversizedRecordWasSkipped

        for observedAt in 2 ... 8 {
            result = try #require(await registry.consume(
                fixture.canonical,
                observedAt: UInt64(observedAt)
            ))
            offsets.append(result.snapshot.nextReadOffset)
            diagnosedOversizedRecord = diagnosedOversizedRecord ||
                result.oversizedRecordWasSkipped
            if result.snapshot.recentEvents.last?.kind == .turnCompleted {
                break
            }
        }

        #expect(diagnosedOversizedRecord)
        #expect(result.snapshot.recentEvents.last?.kind == .turnCompleted)
        #expect(offsets.count >= 3)
        for index in offsets.indices.dropFirst() {
            #expect(offsets[index] > offsets[index - 1])
        }
    }

    @Test("A small unterminated record waits for its newline")
    func unterminatedRecordIsNotSkipped() async throws {
        let fixture = try RegistryFixture(initial:
            RegistryFixture.sessionMetadata +
            RegistryFixture.taskStarted +
            #"{"type":"response_item""#
        )
        defer { fixture.remove() }
        let registry = AgentTranscriptRegistry(configuration: .init(
            maximumReadBytesPerFile: 4 * 1_024,
            startupReplayBytes: 64 * 1_024
        ))

        let first = try #require(await registry.consume(
            fixture.canonical,
            observedAt: 1
        ))
        let second = try #require(await registry.consume(
            fixture.canonical,
            observedAt: 2
        ))
        #expect(second.snapshot.nextReadOffset == first.snapshot.nextReadOffset)
        #expect(!second.oversizedRecordWasSkipped)

        try fixture.append(#", "payload":{}}"# + "\n" + RegistryFixture.taskCompleted)
        let completed = try #require(await registry.consume(
            fixture.canonical,
            observedAt: 3
        ))
        #expect(completed.snapshot.recentEvents.last?.kind == .turnCompleted)
        #expect(!completed.oversizedRecordWasSkipped)
    }

    @Test("Startup replay can cross several chunks of one partial record")
    func startupReplayDiscardEventuallyResumesParsing() async throws {
        let fixture = try RegistryFixture(initial:
            RegistryFixture.sessionMetadata +
            RegistryFixture.ignoredRecord(payloadBytes: 13 * 1_024) +
            RegistryFixture.taskCompleted
        )
        defer { fixture.remove() }
        let registry = AgentTranscriptRegistry(configuration: .init(
            maximumReadBytesPerFile: 4 * 1_024,
            startupReplayBytes: 8 * 1_024
        ))

        let first = try #require(await registry.consume(
            fixture.canonical,
            observedAt: 1
        ))
        #expect(first.snapshot.replayWasTruncated)
        let second = try #require(await registry.consume(
            fixture.canonical,
            observedAt: 2
        ))
        #expect(second.snapshot.nextReadOffset > first.snapshot.nextReadOffset)
        #expect(second.snapshot.recentEvents.last?.kind == .turnCompleted)

        try fixture.append(RegistryFixture.taskStarted)
        let resumed = try #require(await registry.consume(
            fixture.canonical,
            observedAt: 3
        ))
        #expect(resumed.snapshot.recentEvents.last?.kind == .turnStarted)
    }
}

private final class RegistryFixture: @unchecked Sendable {
    static let sessionMetadata =
        #"{"type":"session_meta","payload":{"cwd":"/tmp/work","source":"cli"}}"# + "\n"
    static let taskStarted =
        #"{"type":"event_msg","payload":{"type":"task_started"}}"# + "\n"
    static let taskCompleted =
        #"{"type":"event_msg","payload":{"type":"task_complete"}}"# + "\n"

    let directory: URL
    let url: URL
    let canonical: AgentCanonicalTranscriptPath

    init(initial: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        url = directory.appendingPathComponent("transcript.jsonl")
        try Data(initial.utf8).write(to: url)
        canonical = AgentCanonicalTranscriptPath(
            provider: .codex,
            canonicalPath: url.path,
            providerSessionID: "11111111-1111-1111-1111-111111111111"
        )
    }

    static func ignoredRecord(payloadBytes: Int) -> String {
        #"{"type":"response_item","payload":{"blob":""# +
            String(repeating: "a", count: payloadBytes) +
            #""}}"# + "\n"
    }

    func append(_ value: String) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(value.utf8))
        try handle.synchronize()
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
