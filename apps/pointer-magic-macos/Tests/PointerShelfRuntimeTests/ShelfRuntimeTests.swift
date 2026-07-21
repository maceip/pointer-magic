import Foundation
import PointerCore
import PointerShelfContracts
import PointerShelfRuntime
import Testing

@Suite("Shelf runtime")
struct ShelfRuntimeTests {
    @Test("Assembler prefers selection and redacts secure targets")
    func assembler() {
        let assembler = ContextAssembler(minimumOCRConfidence: 0.2)
        let secure = assembler.assemble(
            ContextAssemblyInput(
                revision: 1,
                generation: 1,
                sequence: 1,
                assembledAtNs: 1,
                point: GlobalPoint(x: 10, y: 20),
                semantic: ContextAssemblySemanticInput(
                    state: "fresh",
                    label: "secret",
                    textAtPoint: "hidden",
                    sensitivityIsSecure: true
                ),
                perception: ContextAssemblyPerceptionInput(
                    state: "fresh",
                    observations: [
                        ContextAssemblyOCRObservation(text: "OCR", confidence: 0.9),
                    ]
                )
            )
        )
        #expect(secure.snippets.isEmpty)
        #expect(secure.hitTarget.selectedText == nil)
        #expect(secure.freshness == .current)

        let open = assembler.assemble(
            ContextAssemblyInput(
                revision: 2,
                generation: 1,
                sequence: 2,
                assembledAtNs: 2,
                point: GlobalPoint(x: 10, y: 20),
                semantic: ContextAssemblySemanticInput(
                    state: "fresh",
                    label: "Subject",
                    textAtPoint: "I'm in town on May 19."
                ),
                perception: ContextAssemblyPerceptionInput(
                    state: "partial",
                    observations: [
                        ContextAssemblyOCRObservation(
                            text: "Let me know what your schedule's looking like",
                            confidence: 0.8
                        ),
                    ]
                )
            )
        )
        #expect(open.snippets.contains(where: { $0.provenance == .selection }))
        #expect(open.snippets.contains(where: { $0.provenance == .ocr }))
        #expect(open.freshness == .partial)
    }

    @Test(
        "Runtime merges primary card with ranked action pills",
        arguments: [
            ("Codex", "codex"),
            ("Claude", "claude"),
        ]
    )
    func mergeAndInvoke(provider: String, providerMark: String) async {
        let runtime = ShelfProviderRuntime()
        let agent = AgentShelfProvider()
        let sample = SampleContextShelfProvider()
        await runtime.register(agent)
        await runtime.register(sample)

        agent.publish(
            AgentShelfProvider.Snapshot(
                identityKey: "agent-key-\(providerMark)",
                provider: provider,
                providerMark: providerMark,
                directoryName: "demo",
                state: "Working",
                revision: 1
            )
        )

        let packet = PointerContextPacket(
            revision: 42,
            generation: 1,
            sequence: 1,
            assembledAtNs: 1,
            point: GlobalPoint(x: 0, y: 0),
            freshness: .current,
            appWindow: PointerContextAppWindow(
                bundleIdentifier: "com.apple.mail",
                applicationName: "Mail"
            ),
            snippets: [
                PointerContextSnippet(
                    id: "s0",
                    text: "I'm in town on May 19.",
                    provenance: .selection
                ),
            ]
        )

        let agentOnly = await agent.propose(packet: packet)
        guard case let .document(compact) = agentOnly else {
            Issue.record("Expected \(provider) compact proposal before merge")
            return
        }
        #expect(compact.fallback?.provider == provider)
        #expect(compact.fallback?.providerMark == providerMark)

        let document = await runtime.propose(using: packet)
        #expect(document?.primary != nil)
        #expect((document?.actions.count ?? 0) >= 3)
        #expect(document?.contextRevision == 42)

        await runtime.park(document: document)
        let result = await runtime.invoke(actionId: "sample.context::view-schedule")
        #expect(result.outcome == .completed)

        let stillFresh = await runtime.invoke(actionId: "sample.context::draft-reply")
        // Still current frozen packet.
        #expect(stillFresh.outcome == .completed)
    }

    @Test(
        "Agent provider emits compact docs for Codex and Claude",
        arguments: [
            ("Codex", "codex"),
            ("Claude", "claude"),
        ]
    )
    func agentProviderCompactAcrossProviders(provider: String, providerMark: String) async {
        let agent = AgentShelfProvider()
        agent.publish(
            AgentShelfProvider.Snapshot(
                identityKey: "\(providerMark)\u{1f}session-1",
                provider: provider,
                providerMark: providerMark,
                directoryName: "webagent-ui",
                state: "Working",
                revision: 3
            )
        )
        let document = await agent.propose(
            packet: PointerContextPacket(
                revision: 7,
                generation: 1,
                sequence: 1,
                assembledAtNs: 1,
                point: GlobalPoint(x: 0, y: 0),
                freshness: .current
            )
        )
        guard case let .document(compact) = document else {
            Issue.record("Expected compact agent document for \(provider)")
            return
        }
        #expect(compact.id == "\(providerMark)\u{1f}session-1")
        #expect(compact.fallback?.provider == provider)
        #expect(compact.fallback?.providerMark == providerMark)
        #expect(compact.fallback?.directoryName == "webagent-ui")
        #expect(compact.fallback?.state == "Working")
        #expect(compact.contextRevision == 7)
    }

    @Test("Stale parked context refuses invoke authority")
    func staleContextDenied() async {
        let runtime = ShelfProviderRuntime()
        let sample = SampleContextShelfProvider()
        await runtime.register(sample)

        let packet = PointerContextPacket(
            revision: 7,
            generation: 1,
            sequence: 1,
            assembledAtNs: 1,
            point: GlobalPoint(x: 0, y: 0),
            freshness: .stale,
            snippets: [
                PointerContextSnippet(id: "s", text: "Hello", provenance: .ocr),
            ]
        )
        let document = await runtime.propose(using: packet)
        await runtime.park(document: document)
        let result = await runtime.invoke(actionId: "sample.context::view-schedule")
        #expect(result.outcome == .denied)
    }
}
