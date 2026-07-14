import Foundation
import PointerSceneContracts
import Testing

@Suite("Atomic scene event batches")
struct EventBatchTests {
    @Test("An identical same-revision replay folds to one event")
    func identicalReplayFolds() throws {
        let epoch = fixtureEpoch()
        let event = try fixtureEnvelope(epoch: epoch, sequence: 1, text: "same")
        let batch = try SceneEventBatch(events: [event, event])

        #expect(batch.events == [event])
        #expect(event.compareReplay(to: event) == .identicalReplay)
    }

    @Test("Different content at one revision is equivocation")
    func equivocationIsRejected() throws {
        let epoch = fixtureEpoch()
        let first = try fixtureEnvelope(epoch: epoch, sequence: 1, text: "first")
        let second = try fixtureEnvelope(epoch: epoch, sequence: 1, text: "second")

        #expect(throws: SceneContractValidationError.revisionEquivocation(sequence: 1)) {
            _ = try SceneEventBatch(events: [first, second])
        }
        #expect(first.compareReplay(to: second) == .equivocation)
    }

    @Test("A batch cannot mix source epochs")
    func mixedEpochIsRejected() throws {
        let first = try fixtureEnvelope(epoch: fixtureEpoch(), sequence: 1, text: "a")
        let second = try fixtureEnvelope(epoch: fixtureEpoch(), sequence: 2, text: "b")

        #expect(throws: SceneContractValidationError.mixedSourceEpoch) {
            _ = try SceneEventBatch(events: [first, second])
        }
    }

    @Test("Out-of-order revisions fail before reducer entry")
    func outOfOrderIsRejected() throws {
        let epoch = fixtureEpoch()
        let second = try fixtureEnvelope(epoch: epoch, sequence: 2, text: "b")
        let first = try fixtureEnvelope(epoch: epoch, sequence: 1, text: "a")

        #expect(throws: SceneContractValidationError.outOfOrder(previous: 2, next: 1)) {
            _ = try SceneEventBatch(events: [second, first])
        }
    }

    @Test("A source sequence gap explicitly breaks coverage")
    func sourceGapBreaksCoverage() throws {
        let epoch = fixtureEpoch()
        let first = try fixtureEnvelope(epoch: epoch, sequence: 1, text: "a")
        let third = try fixtureEnvelope(epoch: epoch, sequence: 3, text: "c")
        let batch = try SceneEventBatch(events: [first, third])

        #expect(batch.requiresCoverageBreak)
        #expect(batch.sourceSequenceGaps == [
            try SourceSequenceGap(sourceEpoch: epoch, missingFrom: 2, missingThrough: 2),
        ])
    }

    @Test("Decoded empty batches are rejected atomically")
    func decodedEmptyBatchIsRejected() throws {
        let data = Data(
            """
            {"schemaVersion":1,"batchID":"00000000-0000-0000-0000-000000000001","events":[]}
            """.utf8
        )

        #expect(throws: SceneContractValidationError.empty(field: "batch.events")) {
            _ = try JSONDecoder().decode(SceneEventBatch.self, from: data)
        }
    }

    @Test("Decoded nested geometry cannot bypass validation")
    func decodedGeometryIsValidated() throws {
        let epoch = fixtureEpoch()
        let event = try regionEnvelope(epoch: epoch, sequence: 1)
        let valid = try JSONEncoder().encode(try SceneEventBatch(events: [event]))
        let object = try JSONSerialization.jsonObject(with: valid)
        let (rewritten, didRewrite) = rewriteCoordinateRevision(in: object, to: 0)
        #expect(didRewrite)
        let invalid = try JSONSerialization.data(withJSONObject: rewritten)

        #expect(
            throws: SceneContractValidationError.invalidRange(
                field: "coordinateSpace.revision"
            )
        ) {
            _ = try JSONDecoder().decode(SceneEventBatch.self, from: invalid)
        }
    }

    @Test("Identifier limits count UTF-8 bytes")
    func utf8ByteLimit() {
        let tooManyBytes = "a" + String(repeating: "é", count: 64)
        #expect(
            throws: SceneContractValidationError.exceedsLimit(
                field: "fieldKey",
                maximum: 128,
                actual: 129
            )
        ) {
            _ = try SceneFieldKey(tooManyBytes)
        }
    }

    @Test("Secure and unknown claims cannot carry values")
    func restrictedClaimsCarryNoValue() throws {
        let field = try SceneFieldKey("content.label")

        #expect(throws: SceneContractValidationError.sensitiveValue(field: "claim.value")) {
            _ = try SceneFieldClaim(
                field: field,
                value: .text("must not enter the event stream"),
                knowledge: .observed,
                confidence: 1,
                sensitivity: .unknown
            )
        }
        #expect(throws: SceneContractValidationError.sensitiveValue(field: "claim.value")) {
            _ = try SceneFieldClaim(
                field: field,
                value: .text("must not enter the event stream"),
                knowledge: .observed,
                confidence: 1,
                sensitivity: .secure
            )
        }
    }

    @Test("A dependency object must share the dependency revision epoch")
    func dependencyEpochConsistency() throws {
        let ownerEpoch = fixtureEpoch()
        let dependencyEpoch = fixtureEpoch()
        let mismatchedEpoch = fixtureEpoch()
        let dependencyRevision = try SourceRevision(
            sourceEpoch: dependencyEpoch,
            sequence: 1
        )
        let claim = try SceneFieldClaim(
            field: SceneFieldKey("content.derived"),
            value: .text("derived"),
            knowledge: .derived,
            confidence: 1,
            sensitivity: .ordinary,
            dependencies: [
                SceneClaimDependency(
                    revision: dependencyRevision,
                    object: SourceObjectKey(
                        sourceEpoch: mismatchedEpoch,
                        objectID: SourceObjectID()
                    )
                ),
            ]
        )
        let observation = try SceneObservation(
            subject: SourceObjectKey(
                sourceEpoch: ownerEpoch,
                objectID: SourceObjectID()
            ),
            observedAtSourceMonotonicNs: 1,
            claims: [claim]
        )

        #expect(
            throws: SceneContractValidationError.sourceMismatch(
                field: "claim.dependencies"
            )
        ) {
            _ = try SceneEventEnvelope(
                revision: SourceRevision(sourceEpoch: ownerEpoch, sequence: 1),
                emittedAtSourceMonotonicNs: 1,
                payload: .observation(observation)
            )
        }
    }
}

private func fixtureEpoch() -> SceneSourceEpoch {
    SceneSourceEpoch(
        source: SceneSourceIdentity(
            device: DevicePrincipalID(),
            source: SceneSourceID()
        )
    )
}

private func fixtureEnvelope(
    epoch: SceneSourceEpoch,
    sequence: UInt64,
    text: String
) throws -> SceneEventEnvelope {
    let revision = try SourceRevision(sourceEpoch: epoch, sequence: sequence)
    let claim = try SceneFieldClaim(
        field: SceneFieldKey("content.label"),
        value: .text(text),
        knowledge: .observed,
        confidence: 1,
        sensitivity: .ordinary,
        evidence: [try SceneEvidence(kind: .accessibility, sourceRevision: revision)]
    )
    let observation = try SceneObservation(
        subject: SourceObjectKey(sourceEpoch: epoch, objectID: SourceObjectID()),
        observedAtSourceMonotonicNs: sequence,
        claims: [claim]
    )
    return try SceneEventEnvelope(
        revision: revision,
        emittedAtSourceMonotonicNs: sequence,
        payload: .observation(observation)
    )
}

private func regionEnvelope(
    epoch: SceneSourceEpoch,
    sequence: UInt64
) throws -> SceneEventEnvelope {
    let revision = try SourceRevision(sourceEpoch: epoch, sequence: sequence)
    let space = try SurfaceCoordinateSpace(
        surface: SceneSurfaceIdentity(
            device: epoch.source.device,
            surfaceID: SceneSurfaceID()
        ),
        coordinateSpaceID: CoordinateSpaceID(),
        revision: 1
    )
    let claim = try SceneFieldClaim(
        field: SceneFieldKey("geometry.bounds"),
        value: .region(
            SurfaceRegion(
                coordinateSpace: space,
                rect: try SceneRect(x: 0, y: 0, width: 10, height: 10)
            )
        ),
        knowledge: .observed,
        confidence: 1,
        sensitivity: .ordinary
    )
    let observation = try SceneObservation(
        subject: SourceObjectKey(sourceEpoch: epoch, objectID: SourceObjectID()),
        observedAtSourceMonotonicNs: sequence,
        claims: [claim]
    )
    return try SceneEventEnvelope(
        revision: revision,
        emittedAtSourceMonotonicNs: sequence,
        payload: .observation(observation)
    )
}

private func rewriteCoordinateRevision(in value: Any, to revision: Int) -> (Any, Bool) {
    if var dictionary = value as? [String: Any] {
        if dictionary["rect"] != nil,
           var coordinateSpace = dictionary["coordinateSpace"] as? [String: Any]
        {
            coordinateSpace["revision"] = revision
            dictionary["coordinateSpace"] = coordinateSpace
            return (dictionary, true)
        }

        for key in dictionary.keys.sorted() {
            let (rewritten, changed) = rewriteCoordinateRevision(
                in: dictionary[key] as Any,
                to: revision
            )
            if changed {
                dictionary[key] = rewritten
                return (dictionary, true)
            }
        }
        return (dictionary, false)
    }

    if var array = value as? [Any] {
        for index in array.indices {
            let (rewritten, changed) = rewriteCoordinateRevision(in: array[index], to: revision)
            if changed {
                array[index] = rewritten
                return (array, true)
            }
        }
        return (array, false)
    }

    return (value, false)
}
